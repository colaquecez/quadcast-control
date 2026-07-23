import Foundation

/// USB vendor IDs relevant to HyperX hardware.
///
/// HyperX was a Kingston brand until 2021, when HP acquired it. Older devices
/// enumerate with the Kingston vendor ID and newer ones with the HP vendor ID,
/// so both must be matched during discovery.
public enum HyperXVendorID {
    /// Kingston Technology (pre-2021 HyperX devices).
    public static let kingston: Int = 0x0951
    /// HP, Inc. (post-acquisition HyperX devices, including the QuadCast 2).
    public static let hp: Int = 0x03F0

    public static let all: [Int] = [kingston, hp]
}

/// A HyperX microphone model this application knows about.
///
/// Commands are **not** interchangeable between models. Each model carries its
/// own protocol implementation (or none, if the protocol is not implemented).
public enum HyperXModel: String, Sendable, Equatable, CaseIterable {
    case quadCast = "QuadCast"
    case quadCastS = "QuadCast S"
    case quadCast2 = "QuadCast 2"
    case quadCast2S = "QuadCast 2 S"
    case duoCast = "DuoCast"
}

/// What a given USB PID actually is. HyperX microphones enumerate as *two*
/// USB devices: an audio device and a separate "Controller" device. LED
/// control always targets the controller PID.
public enum DeviceRole: String, Sendable, Equatable {
    case ledController = "LED controller"
    case audio = "Audio"
}

/// How LED command bytes must be delivered to a given device on macOS.
public enum SendPath: Sendable, Equatable, Hashable {
    /// Regular HID reports through `IOHIDDeviceSetReport`.
    case hidReports
    /// Raw HID-class SET_REPORT control transfers on endpoint 0, targeting
    /// the given USB interface number. Required when the firmware accepts
    /// reports its HID descriptor does not declare (QuadCast 2: descriptor
    /// declares no writable reports, so the HID stack refuses; verified on
    /// hardware 2026-07-22).
    case controlTransfer(interface: UInt16)
}

/// One (vendorID, productID) pair in the strict device allowlist.
public struct KnownDeviceID: Sendable, Equatable, Hashable {
    public let vendorID: Int
    public let productID: Int
    public let model: HyperXModel
    public let role: DeviceRole
    /// Whether this PID accepts any LED commands at all. False for audio-side
    /// PIDs and for models with no controllable LEDs (original QuadCast).
    public let supportsLEDControl: Bool
    /// The HID usage page of the interface LED commands must target, when the
    /// controller exposes several interfaces. nil = any.
    public let preferredUsagePage: Int?
    /// How command bytes reach this device on macOS.
    public let sendPath: SendPath
    /// Where this VID/PID pair was documented (public source), for audit.
    public let source: String

    public init(
        vendorID: Int,
        productID: Int,
        model: HyperXModel,
        role: DeviceRole,
        supportsLEDControl: Bool,
        preferredUsagePage: Int? = nil,
        sendPath: SendPath = .hidReports,
        source: String
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.model = model
        self.role = role
        self.supportsLEDControl = supportsLEDControl
        self.preferredUsagePage = preferredUsagePage
        self.sendPath = sendPath
        self.source = source
    }
}

/// The strict allowlist of devices this application recognizes. Discovery may
/// *list* any HyperX-vendor HID interface in debug mode, but the transport
/// layer refuses to open anything that is not in this table with
/// `supportsLEDControl == true`.
///
/// Provenance for every entry is documented in PROTOCOL.md. Sources:
/// - quadcastrgb (github.com/Ors1mer/QuadcastRGB) source + issues #4/5/8/11/18/21
/// - OpenRGB HyperXMicrophoneController / HyperXMicrophoneV2Controller detectors
public enum DeviceAllowlist {
    public static let devices: [KnownDeviceID] = [
        // ── QuadCast 2 (non-S) ─────────────────────────────────────────────
        // LEDs are red-only; the documented protocol controls brightness.
        KnownDeviceID(
            vendorID: HyperXVendorID.hp, productID: 0x09AF,
            model: .quadCast2, role: .ledController, supportsLEDControl: true,
            preferredUsagePage: nil,
            // The controller's HID descriptor declares no writable reports
            // (max feature/output size 1), so IOHIDDeviceSetReport stalls.
            // Commands must go out as raw SET_REPORT control transfers to
            // interface 0 — hardware-verified by this project.
            sendPath: .controlTransfer(interface: 0),
            source: "quadcastrgb issue #21 (merged upstream)"
        ),
        KnownDeviceID(
            vendorID: HyperXVendorID.hp, productID: 0x07B4,
            model: .quadCast2, role: .audio, supportsLEDControl: false,
            source: "quadcastrgb issue #21"
        ),
        // ── QuadCast 2 S ───────────────────────────────────────────────────
        // Per-LED RGB (12×9 matrix, 108 LEDs) on the interface with vendor
        // usage page 0xFF13.
        KnownDeviceID(
            vendorID: HyperXVendorID.hp, productID: 0x02B5,
            model: .quadCast2S, role: .ledController, supportsLEDControl: true,
            preferredUsagePage: 0xFF13,
            source: "quadcastrgb issue #18; OpenRGB MR !3039"
        ),
        KnownDeviceID(
            vendorID: HyperXVendorID.hp, productID: 0x0D84,
            model: .quadCast2S, role: .audio, supportsLEDControl: false,
            source: "quadcastrgb issue #18"
        ),
        // ── QuadCast S (Kingston + HP revisions) ───────────────────────────
        KnownDeviceID(
            vendorID: HyperXVendorID.kingston, productID: 0x171F,
            model: .quadCastS, role: .ledController, supportsLEDControl: true,
            preferredUsagePage: 0xFF90,
            source: "quadcastrgb devio.c; OpenRGB"
        ),
        KnownDeviceID(
            vendorID: HyperXVendorID.kingston, productID: 0x171D,
            model: .quadCastS, role: .audio, supportsLEDControl: false,
            source: "quadcastrgb issue #4"
        ),
        KnownDeviceID(
            vendorID: HyperXVendorID.hp, productID: 0x0F8B,
            model: .quadCastS, role: .ledController, supportsLEDControl: true,
            preferredUsagePage: 0xFF90,
            source: "quadcastrgb devio.c"
        ),
        KnownDeviceID(
            vendorID: HyperXVendorID.hp, productID: 0x028C,
            model: .quadCastS, role: .ledController, supportsLEDControl: true,
            preferredUsagePage: 0xFF90,
            source: "quadcastrgb issue #5"
        ),
        KnownDeviceID(
            vendorID: HyperXVendorID.hp, productID: 0x048C,
            model: .quadCastS, role: .ledController, supportsLEDControl: true,
            preferredUsagePage: 0xFF90,
            source: "quadcastrgb issue #8"
        ),
        KnownDeviceID(
            vendorID: HyperXVendorID.hp, productID: 0x068C,
            model: .quadCastS, role: .ledController, supportsLEDControl: true,
            preferredUsagePage: 0xFF90,
            source: "quadcastrgb issue #8"
        ),
        // ── DuoCast (QuadCast S-compatible protocol) ───────────────────────
        KnownDeviceID(
            vendorID: HyperXVendorID.hp, productID: 0x098C,
            model: .duoCast, role: .ledController, supportsLEDControl: true,
            preferredUsagePage: 0xFF90,
            source: "quadcastrgb issue #11; OpenRGB"
        ),
        // ── Original QuadCast: fixed red LED, no USB LED control exists ────
        KnownDeviceID(
            vendorID: HyperXVendorID.kingston, productID: 0x16DF,
            model: .quadCast, role: .audio, supportsLEDControl: false,
            source: "usb.ids; quadcastrgb issue #4"
        ),
        KnownDeviceID(
            vendorID: HyperXVendorID.hp, productID: 0x0491,
            model: .quadCast, role: .audio, supportsLEDControl: false,
            source: "quadcastrgb issue #13"
        ),
    ]

    public static func lookup(vendorID: Int, productID: Int) -> KnownDeviceID? {
        devices.first { $0.vendorID == vendorID && $0.productID == productID }
    }

    /// Whether a vendor ID is worth inspecting at all during discovery.
    public static func isCandidateVendor(_ vendorID: Int) -> Bool {
        HyperXVendorID.all.contains(vendorID)
    }
}
