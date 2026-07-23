import Foundation

/// In-memory transport used by unit tests and the hardware-free development
/// mode. Records everything sent to it and can simulate disconnection.
public final class MockHIDTransport: HIDTransport, @unchecked Sendable {
    private let lock = NSLock()

    public let info: HIDDeviceInfo

    private var _isOpen = false
    private var _disconnected = false
    private var _sentReports: [HIDReport] = []
    private var disconnectHandler: (@Sendable () -> Void)?
    /// Canned responses for `getFeatureReport`, keyed by report ID.
    private var featureResponses: [UInt8: [UInt8]] = [:]
    /// When true, `open()` ignores the allowlist (to test the unsupported path
    /// the default is false, i.e. behave like the real transport).
    public let bypassAllowlist: Bool

    public init(info: HIDDeviceInfo, bypassAllowlist: Bool = false) {
        self.info = info
        self.bypassAllowlist = bypassAllowlist
    }

    // MARK: HIDTransport

    public var isOpen: Bool {
        lock.withLock { _isOpen }
    }

    public func open() throws(HIDTransportError) {
        if !bypassAllowlist, info.knownDevice?.supportsLEDControl != true {
            throw .unsupportedDevice(vendorID: info.vendorID, productID: info.productID)
        }
        let disconnected = lock.withLock { _disconnected }
        if disconnected { throw .deviceDisconnected }
        lock.withLock { _isOpen = true }
    }

    public func close() {
        lock.withLock { _isOpen = false }
    }

    public func send(_ report: HIDReport, policy: HIDReportPolicy) throws(HIDTransportError) {
        try policy.validate(report)
        try lock.withLockTyped { () throws(HIDTransportError) -> Void in
            if _disconnected { throw .deviceDisconnected }
            guard _isOpen else { throw .deviceNotOpen }
            _sentReports.append(report)
        }
    }

    public func getFeatureReport(
        reportID: UInt8,
        maxLength: Int
    ) throws(HIDTransportError) -> [UInt8] {
        try lock.withLockTyped { () throws(HIDTransportError) -> [UInt8] in
            if _disconnected { throw .deviceDisconnected }
            guard _isOpen else { throw .deviceNotOpen }
            guard let response = featureResponses[reportID] else {
                throw .unsupportedReportID(reportID)
            }
            return Array(response.prefix(maxLength))
        }
    }

    public func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { disconnectHandler = handler }
    }

    // MARK: Input monitoring

    private var inputHandler: (@Sendable (HIDInputReport) -> Void)?

    public func startInputReportMonitoring(
        _ handler: @escaping @Sendable (HIDInputReport) -> Void
    ) throws(HIDTransportError) {
        try lock.withLockTyped { () throws(HIDTransportError) -> Void in
            if _disconnected { throw .deviceDisconnected }
            guard _isOpen else { throw .deviceNotOpen }
            inputHandler = handler
        }
    }

    public func stopInputReportMonitoring() {
        lock.withLock { inputHandler = nil }
    }

    /// Test control: simulates the device emitting an input report (e.g. a
    /// knob turn).
    public func emitInputReport(reportID: UInt8, bytes: [UInt8]) {
        let handler = lock.withLock { inputHandler }
        handler?(HIDInputReport(deviceID: info.id, reportID: reportID, bytes: bytes))
    }

    // MARK: Test controls

    /// Everything successfully sent through this transport, in order.
    public var sentReports: [HIDReport] {
        lock.withLock { _sentReports }
    }

    public func clearSentReports() {
        lock.withLock { _sentReports.removeAll() }
    }

    public func stubFeatureReport(id: UInt8, response: [UInt8]) {
        lock.withLock { featureResponses[id] = response }
    }

    /// Simulates the cable being yanked: all future I/O fails and the
    /// registered disconnect handler fires exactly once.
    public func simulateDisconnect() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !_disconnected else { return nil }
            _disconnected = true
            _isOpen = false
            let h = disconnectHandler
            disconnectHandler = nil
            return h
        }
        handler?()
    }

    /// A plausible QuadCast 2-shaped mock interface for previews and tests.
    /// The product ID is intentionally a placeholder outside the allowlist
    /// unless `allowlisted` uses a real known device.
    public static func makeInfo(
        id: UInt64 = 1,
        vendorID: Int = HyperXVendorID.hp,
        productID: Int = 0x0000,
        name: String = "Mock HyperX Microphone",
        usagePage: Int = 0xFF00,
        usage: Int = 0x01
    ) -> HIDDeviceInfo {
        HIDDeviceInfo(
            id: id,
            name: name,
            vendorID: vendorID,
            productID: productID,
            usagePage: usagePage,
            usage: usage,
            redactedSerial: "…MOCK",
            transportKind: "Mock",
            maxInputReportLength: 64,
            maxOutputReportLength: 64,
            maxFeatureReportLength: 64,
            reportDescriptor: nil
        )
    }
}
