import Foundation

/// `NSLock.withLock` is `rethrows` and erases typed errors; this variant
/// preserves them so transport methods can keep `throws(HIDTransportError)`.
extension NSLock {
    func withLockTyped<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// The three HID report categories. Raw values match `IOHIDReportType`.
public enum HIDReportKind: Int, Sendable, Equatable {
    case input = 0
    case output = 1
    case feature = 2
}

/// Errors thrown by the HID transport layer.
public enum HIDTransportError: Error, Equatable, Sendable {
    case deviceNotOpen
    case deviceDisconnected
    case openFailed(code: Int32)
    case ioError(code: Int32)
    case invalidReportLength(expected: Int, actual: Int)
    case unsupportedReportID(UInt8)
    case unsupportedDevice(vendorID: Int, productID: Int)
    case emptyPayload
    /// The transport cannot deliver input reports (e.g. the raw
    /// control-transfer transport has no HID event stream).
    case monitoringNotSupported
}

/// One input report received from a device — the read-only event stream used
/// by the diagnostics monitor (knob turns, mute touches, …).
public struct HIDInputReport: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Registry ID of the interface that produced the report.
    public let deviceID: UInt64
    public let reportID: UInt8
    public let bytes: [UInt8]
    public let date: Date

    public init(deviceID: UInt64, reportID: UInt8, bytes: [UInt8], date: Date = Date()) {
        self.id = UUID()
        self.deviceID = deviceID
        self.reportID = reportID
        self.bytes = bytes
        self.date = date
    }

    public var hexDescription: String {
        "id=0x\(String(format: "%02X", reportID)) " + HexDump.compact(bytes)
    }
}

/// A fully-formed HID report ready for the transport.
///
/// macOS semantics (differ from hidapi on Linux!): `payload` must NOT contain
/// the report ID byte. `IOHIDDeviceSetReport` receives the report ID as a
/// separate parameter. When porting packet captures that show a leading report
/// ID byte, strip it before constructing a `HIDReport`.
public struct HIDReport: Sendable, Equatable {
    public let kind: HIDReportKind
    public let reportID: UInt8
    public let payload: [UInt8]

    public init(kind: HIDReportKind, reportID: UInt8, payload: [UInt8]) {
        self.kind = kind
        self.reportID = reportID
        self.payload = payload
    }

    public var hexDescription: String {
        "[\(kind)] id=0x\(String(format: "%02X", reportID)) len=\(payload.count) " + HexDump.compact(payload)
    }
}

/// Per-device constraints used to validate reports before they reach IOKit.
///
/// Values come from the device's HID report descriptor (max report sizes) and
/// from the protocol allowlist (permitted report IDs). Anything outside these
/// bounds is refused in software — nothing malformed is ever handed to the OS.
public struct HIDReportPolicy: Sendable, Equatable {
    /// Report IDs this device's protocol is allowed to use, per kind.
    public let allowedReportIDs: [HIDReportKind: Set<UInt8>]
    /// Maximum payload byte counts, per kind (excluding the report ID byte).
    public let maxPayloadLength: [HIDReportKind: Int]

    public init(
        allowedReportIDs: [HIDReportKind: Set<UInt8>],
        maxPayloadLength: [HIDReportKind: Int]
    ) {
        self.allowedReportIDs = allowedReportIDs
        self.maxPayloadLength = maxPayloadLength
    }

    /// A policy that refuses every write. Used for devices whose protocol is
    /// unknown — read-only diagnostics remain possible, writes do not.
    public static let readOnly = HIDReportPolicy(
        allowedReportIDs: [:],
        maxPayloadLength: [:]
    )

    public func validate(_ report: HIDReport) throws(HIDTransportError) {
        guard !report.payload.isEmpty else {
            throw .emptyPayload
        }
        guard let ids = allowedReportIDs[report.kind], ids.contains(report.reportID) else {
            throw .unsupportedReportID(report.reportID)
        }
        guard let maxLength = maxPayloadLength[report.kind] else {
            throw .unsupportedReportID(report.reportID)
        }
        guard report.payload.count <= maxLength else {
            throw .invalidReportLength(expected: maxLength, actual: report.payload.count)
        }
    }
}
