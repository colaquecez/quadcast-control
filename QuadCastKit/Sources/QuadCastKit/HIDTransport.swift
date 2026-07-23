import Foundation

/// A snapshot of one HID interface, safe to pass across concurrency domains.
public struct HIDDeviceInfo: Sendable, Equatable, Identifiable {
    /// Stable identity for the lifetime of the connection (IOKit registry ID
    /// for real devices, arbitrary for mocks).
    public let id: UInt64
    public let name: String
    public let vendorID: Int
    public let productID: Int
    public let usagePage: Int
    public let usage: Int
    /// Serial number with all but the last four characters redacted, or nil.
    /// The full serial is deliberately never stored or logged.
    public let redactedSerial: String?
    public let transportKind: String
    public let maxInputReportLength: Int
    public let maxOutputReportLength: Int
    public let maxFeatureReportLength: Int
    /// Raw HID report descriptor, when the OS exposes it. Read-only data used
    /// by the diagnostics screen.
    public let reportDescriptor: [UInt8]?

    /// The allowlist entry this interface matched, if any.
    public var knownDevice: KnownDeviceID? {
        DeviceAllowlist.lookup(vendorID: vendorID, productID: productID)
    }

    public init(
        id: UInt64,
        name: String,
        vendorID: Int,
        productID: Int,
        usagePage: Int,
        usage: Int,
        redactedSerial: String?,
        transportKind: String,
        maxInputReportLength: Int,
        maxOutputReportLength: Int,
        maxFeatureReportLength: Int,
        reportDescriptor: [UInt8]?
    ) {
        self.id = id
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
        self.usage = usage
        self.redactedSerial = redactedSerial
        self.transportKind = transportKind
        self.maxInputReportLength = maxInputReportLength
        self.maxOutputReportLength = maxOutputReportLength
        self.maxFeatureReportLength = maxFeatureReportLength
        self.reportDescriptor = reportDescriptor
    }

    /// Redacts a serial number down to its last four characters.
    public static func redactSerial(_ serial: String?) -> String? {
        guard let serial, !serial.isEmpty else { return nil }
        let suffix = serial.suffix(4)
        return "…\(suffix)"
    }
}

/// Internal hook the discovery layer uses to tell a transport its device is
/// gone before dropping it.
protocol DisconnectMarkable: AnyObject {
    func markDisconnected()
}

/// Abstract HID transport. `IOKitHIDTransport` talks to real hardware over
/// HID reports, `USBControlTransport` over raw EP0 control transfers;
/// `MockHIDTransport` backs unit tests and the no-hardware development mode.
///
/// Implementations must be safe to call from any thread/task and must survive
/// the device disappearing mid-call (returning `.deviceDisconnected` rather
/// than crashing).
public protocol HIDTransport: AnyObject, Sendable {
    var info: HIDDeviceInfo { get }
    var isOpen: Bool { get }

    /// Opens the underlying device for I/O. Throws `.unsupportedDevice` if the
    /// interface is not in the allowlist — the transport is the last line of
    /// defense, even if a caller forgets to check.
    func open() throws(HIDTransportError)
    func close()

    /// Sends a feature or output report after validating it against `policy`.
    func send(_ report: HIDReport, policy: HIDReportPolicy) throws(HIDTransportError)

    /// Reads a feature report, when the device supports it.
    func getFeatureReport(reportID: UInt8, maxLength: Int) throws(HIDTransportError) -> [UInt8]

    /// Registers a handler invoked once if the device disconnects while open.
    func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void)
}
