import Foundation

/// How much trust we have in an encoded packet's byte structure.
public enum CommandVerification: Sendable, Equatable {
    /// Byte structure confirmed working on this exact model on real hardware,
    /// by a credible public source (cited) or by this project.
    case verified(source: String)
    /// Byte structure is a hypothesis and must never be sent automatically.
    case unverified(hypothesisSource: String)
}

/// A packet produced by a protocol encoder, before transport validation.
public struct EncodedCommand: Sendable, Equatable {
    public let report: HIDReport
    public let verification: CommandVerification
    /// Pause required *after* this packet before the next one (some devices
    /// need inter-packet gaps, e.g. QuadCast 2 wants ~20 ms before its
    /// heartbeat).
    public let postDelay: Duration

    public init(
        report: HIDReport,
        verification: CommandVerification,
        postDelay: Duration = .zero
    ) {
        self.report = report
        self.verification = verification
        self.postDelay = postDelay
    }

    public var isVerified: Bool {
        if case .verified = verification { return true }
        return false
    }
}

/// Errors from the protocol-encoding layer.
public enum ProtocolError: Error, Equatable, Sendable {
    /// The byte structure for this operation on this model is not known.
    /// The app must degrade gracefully, not guess.
    case commandNotYetVerified(model: HyperXModel)
    /// The device hardware cannot do this (e.g. color on the red-only
    /// QuadCast 2).
    case unsupportedByHardware(model: HyperXModel, what: String)
    case packetBuildFailed
}

/// What a device's LEDs can actually do.
public struct LightingCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let onOff = LightingCapabilities(rawValue: 1 << 0)
    public static let brightness = LightingCapabilities(rawValue: 1 << 1)
    public static let staticColor = LightingCapabilities(rawValue: 1 << 2)
    /// Supports persisting the current look to device flash.
    public static let persistence = LightingCapabilities(rawValue: 1 << 3)
}

/// A model-specific encoder from desired `LightingState` to HID packets.
///
/// Encoders are *pure*: they translate state to bytes and never talk to a
/// device. The `LightingService` owns timing (debounce, refresh loop) and the
/// transport owns I/O.
public protocol LightingProtocolEncoding: Sendable {
    var model: HyperXModel { get }
    var capabilities: LightingCapabilities { get }
    /// Report policy (allowed report IDs + max lengths) for this protocol.
    var reportPolicy: HIDReportPolicy { get }

    /// The packet sequence that makes the device show `state`.
    func apply(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand]

    /// Some devices revert to their own lighting when host traffic stops and
    /// therefore need periodic refresh. nil = no refresh needed.
    var refreshInterval: Duration? { get }
    /// Packets to send on each refresh tick (often the same as `apply`).
    func refresh(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand]

    /// Persist-to-flash sequence, for devices that support `.persistence`.
    func save(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand]
}

/// Builds fixed-size HID packets with explicit length validation. Pure
/// function of its inputs — unit-tested without hardware.
public enum HIDPacketBuilder {
    public enum BuildError: Error, Equatable, Sendable {
        case payloadTooLong(max: Int, actual: Int)
    }

    /// Frames `bytes` into a packet of exactly `length` bytes, zero-padded.
    /// All HyperX microphone protocols observed so far use fixed 64-byte
    /// packets, so short payloads are padded rather than sent short.
    public static func fixedLength(
        _ bytes: [UInt8],
        length: Int
    ) throws(BuildError) -> [UInt8] {
        guard bytes.count <= length else {
            throw .payloadTooLong(max: length, actual: bytes.count)
        }
        return bytes + [UInt8](repeating: 0, count: length - bytes.count)
    }
}

// MARK: - QuadCast 2 (non-S)

/// Protocol encoder for the HyperX QuadCast 2 (PID 0x09AF).
///
/// ── STATUS: community-verified, brightness only ────────────────────────────
/// Source: quadcastrgb issue #21 (github.com/Ors1mer/QuadcastRGB/issues/21),
/// reverse-engineered from USB captures of NGENUITY 5.34 and merged into
/// quadcastrgb main; independently confirmed working by multiple users.
///
/// Hardware facts (why the API surface is small):
/// - The QuadCast 2's LEDs are red-only. There is NO color command; the
///   "R byte" of the legacy color command acts as global brightness.
/// - There is no known save-to-flash; NGENUITY's own save fails on this
///   device. The mic reverts to 100% brightness ~1 s after traffic stops,
///   so a heartbeat must be sent continuously (every ~500 ms).
///
/// Wire format — 64-byte feature reports, report ID 0 (SET_REPORT
/// wValue 0x0300, wIndex 0, wLength 64):
/// - Brightness:  `81 XX 00 00 81 XX 00 00` + 56 zero bytes,
///   XX = brightness in 0x00...0xF2 (0xF2 = max).
/// - Heartbeat:   `04 XX 00 00 00 00 00 00 01 00` + 54 zero bytes,
///   where XX MUST equal the current brightness or the LED flickers.
/// - Sequence: brightness → ~20 ms → heartbeat → ~500 ms → repeat.
/// ───────────────────────────────────────────────────────────────────────────
public struct QuadCast2Protocol: LightingProtocolEncoding {
    public let model: HyperXModel = .quadCast2
    public let capabilities: LightingCapabilities = [.onOff, .brightness]

    static let packetLength = 64
    /// Device brightness range is 0x00...0xF2, NOT 0...255.
    static let maxDeviceBrightness: Double = 0xF2

    static let verification = CommandVerification.verified(
        source: "quadcastrgb issue #21; merged into quadcastrgb main; community-tested"
    )

    public var reportPolicy: HIDReportPolicy {
        HIDReportPolicy(
            allowedReportIDs: [.feature: [0x00]],
            maxPayloadLength: [.feature: Self.packetLength]
        )
    }

    public init() {}

    /// Maps 0...100% onto the device's 0x00...0xF2 scale.
    static func deviceBrightness(for state: LightingState) -> UInt8 {
        guard state.isOn else { return 0x00 }
        let unit = Double(state.brightness.percent) / 100.0
        return UInt8((unit * maxDeviceBrightness).rounded())
    }

    public func apply(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        let level = Self.deviceBrightness(for: state)
        return [
            EncodedCommand(
                report: HIDReport(
                    kind: .feature, reportID: 0x00,
                    payload: Self.pad([0x81, level, 0x00, 0x00, 0x81, level, 0x00, 0x00])
                ),
                verification: Self.verification,
                // Observed timing: ~20 ms between brightness and heartbeat.
                postDelay: .milliseconds(20)
            ),
            EncodedCommand(
                report: HIDReport(
                    kind: .feature, reportID: 0x00,
                    payload: Self.pad([0x04, level, 0, 0, 0, 0, 0, 0, 0x01, 0x00])
                ),
                verification: Self.verification
            ),
        ]
    }

    /// The device reverts to full brightness ~1 s after traffic stops, so the
    /// full apply sequence is re-sent continuously while control is active.
    public var refreshInterval: Duration? { .milliseconds(500) }

    public func refresh(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        try apply(state)
    }

    public func save(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        // NGENUITY itself cannot persist settings on this device.
        throw .unsupportedByHardware(model: model, what: "save-to-device")
    }

    private static func pad(_ bytes: [UInt8]) -> [UInt8] {
        // Payloads above are always ≤ 64 bytes by construction; a builder
        // failure here would be a programming error, so fall back to the raw
        // bytes rather than trapping (transport validation still applies).
        (try? HIDPacketBuilder.fixedLength(bytes, length: packetLength)) ?? bytes
    }
}

// MARK: - QuadCast 2 S

/// Protocol encoder for the HyperX QuadCast 2 S (PID 0x02B5, the HID
/// interface with vendor usage page 0xFF13).
///
/// ── STATUS: community-verified ─────────────────────────────────────────────
/// Sources: quadcastrgb issue #18 (packet captures + working implementation),
/// OpenRGB HyperXMicrophoneV2Controller (merged to OpenRGB master 2025-10,
/// MR !3039). Verified against a real NGENUITY capture (`#c90076` appears as
/// `44 02 02 00 c9 00 76 ...`).
///
/// Wire format — 64-byte packets on the vendor interface; the first byte
/// (0x44/0x42/0x40) is the command family:
/// - Direct mode:
///   1. header `44 01 06 00...`            (announce 6 data packets)
///   2. six packets `44 02 <idx 0-5> 00` + 20 RGB triplets from byte 4
///      (120 LED slots; the device has a 12×9 matrix = 108 LEDs used).
/// - Save-to-flash: `44 03 01 06...`, six `44 04 <idx> ...` data packets,
///   framerate packet `42 02 00 00 00 E8 03...`, commit `40 01 00 00 FF...`.
/// - The device answers every packet on its interrupt-IN endpoint; macOS's
///   HID stack drains that endpoint for us, and responses are surfaced to the
///   diagnostics log when input reporting is enabled.
///
/// TODO(hardware): confirm on real hardware whether this interface's report
/// descriptor declares report IDs. This encoder assumes it does NOT (the wire
/// bytes start with 0x44 as *data*, report ID 0), matching the raw captures.
/// If writes fail with a report-ID error, flip `usesNumberedReports`.
/// ───────────────────────────────────────────────────────────────────────────
public struct QuadCast2SProtocol: LightingProtocolEncoding {
    public let model: HyperXModel = .quadCast2S
    public let capabilities: LightingCapabilities = [.onOff, .brightness, .staticColor, .persistence]

    static let packetLength = 64
    static let ledCount = 108
    static let ledSlots = 120
    static let dataPacketCount = 6
    static let tripletsPerPacket = 20

    static let verification = CommandVerification.verified(
        source: "quadcastrgb issue #18; OpenRGB HyperXMicrophoneV2Controller (MR !3039)"
    )

    public var reportPolicy: HIDReportPolicy {
        HIDReportPolicy(
            allowedReportIDs: [.output: [0x00]],
            maxPayloadLength: [.output: Self.packetLength]
        )
    }

    public init() {}

    /// Host-side brightness: the protocol has no separate brightness field,
    /// so color channels are scaled (exactly what OpenRGB does).
    static func scaledColor(for state: LightingState) -> RGBColor {
        guard state.isOn else { return .black }
        let factor = Double(state.brightness.percent) / 100.0
        return RGBColor(
            red: UInt8((Double(state.color.red) * factor).rounded()),
            green: UInt8((Double(state.color.green) * factor).rounded()),
            blue: UInt8((Double(state.color.blue) * factor).rounded())
        )
    }

    public func apply(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        let color = Self.scaledColor(for: state)
        var packets: [EncodedCommand] = [
            command([0x44, 0x01, UInt8(Self.dataPacketCount), 0x00])
        ]
        for index in 0..<Self.dataPacketCount {
            packets.append(command(Self.dataPacket(prefix: [0x44, 0x02, UInt8(index), 0x00], color: color)))
        }
        return packets
    }

    /// Streaming keeps the look alive; the mic reverts to its onboard rainbow
    /// effect when host traffic stops (exact timeout undocumented — 250 ms is
    /// the conservative refresh used here; use "Save to device" for a
    /// traffic-free persistent look).
    public var refreshInterval: Duration? { .milliseconds(250) }

    public func refresh(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        try apply(state)
    }

    public func save(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        let color = Self.scaledColor(for: state)
        var packets: [EncodedCommand] = [
            command([0x44, 0x03, 0x01, UInt8(Self.dataPacketCount)])
        ]
        for index in 0..<Self.dataPacketCount {
            packets.append(command(Self.dataPacket(prefix: [0x44, 0x04, UInt8(index), 0x00], color: color)))
        }
        // "Framerate" packet — 0x03E8 = 1000, little-endian at offsets 5-6,
        // as sent by NGENUITY for a static look (per OpenRGB).
        packets.append(command([0x42, 0x02, 0x00, 0x00, 0x00, 0xE8, 0x03]))
        // Commit.
        packets.append(command([0x40, 0x01, 0x00, 0x00, 0xFF]))
        return packets
    }

    private static func dataPacket(prefix: [UInt8], color: RGBColor) -> [UInt8] {
        var bytes = prefix
        for _ in 0..<tripletsPerPacket {
            bytes += [color.red, color.green, color.blue]
        }
        return bytes
    }

    private func command(_ bytes: [UInt8]) -> EncodedCommand {
        let payload = (try? HIDPacketBuilder.fixedLength(bytes, length: Self.packetLength)) ?? bytes
        return EncodedCommand(
            report: HIDReport(kind: .output, reportID: 0x00, payload: payload),
            verification: Self.verification,
            // quadcastrgb spaces packets ~700 µs apart; 2 ms is comfortably
            // conservative without visible lag.
            postDelay: .milliseconds(2)
        )
    }
}

// MARK: - Registry

/// Picks the encoder for a discovered device, or nil when the device is
/// recognized but no protocol is implemented (the UI then stays read-only).
public enum ProtocolRegistry {
    public static func encoder(for device: KnownDeviceID) -> (any LightingProtocolEncoding)? {
        guard device.supportsLEDControl else { return nil }
        switch device.model {
        case .quadCast2:
            return QuadCast2Protocol()
        case .quadCast2S:
            return QuadCast2SProtocol()
        case .quadCast, .quadCastS, .duoCast:
            // The QuadCast S / DuoCast protocol is publicly documented (see
            // PROTOCOL.md) but not implemented in this app yet; the original
            // QuadCast has no controllable LEDs at all.
            return nil
        }
    }
}
