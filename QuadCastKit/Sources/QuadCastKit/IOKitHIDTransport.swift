import Foundation
import IOKit.hid

/// Real transport over an `IOHIDDevice`.
///
/// Threading: `IOHIDDeviceSetReport`/`GetReport` are synchronous and safe to
/// call from any thread on an opened device; a lock guards the open/closed
/// state. Disconnection is signalled by the discovery layer (which observes
/// removal callbacks) via `markDisconnected()` — after that every call fails
/// with `.deviceDisconnected` instead of touching the dead IOKit handle.
public final class IOKitHIDTransport: HIDTransport, DisconnectMarkable, @unchecked Sendable {
    public let info: HIDDeviceInfo

    private let device: IOHIDDevice
    private let lock = NSLock()
    private var _isOpen = false
    private var _disconnected = false
    /// True when opened via `openForMonitoring()` on a non-LED interface:
    /// input reports may be read, but `send` is refused.
    private var _monitorOnly = false
    private var disconnectHandler: (@Sendable () -> Void)?
    private var inputHandler: (@Sendable (HIDInputReport) -> Void)?
    /// Stable buffer IOKit writes incoming reports into; must outlive the
    /// registered callback.
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputBufferLength = 0
    private let log: HIDLog

    public init(device: IOHIDDevice, info: HIDDeviceInfo, log: HIDLog = .shared) {
        self.device = device
        self.info = info
        self.log = log
    }

    public var isOpen: Bool { lock.withLock { _isOpen } }

    public func open() throws(HIDTransportError) {
        // Strict allowlist: never open an interface we cannot positively
        // identify as an LED controller, even if a caller asks us to.
        guard info.knownDevice?.supportsLEDControl == true else {
            throw .unsupportedDevice(vendorID: info.vendorID, productID: info.productID)
        }
        try lock.withLockTyped { () throws(HIDTransportError) -> Void in
            if _disconnected { throw .deviceDisconnected }
            guard !_isOpen else { return }
            // kIOHIDOptionsTypeNone: shared, non-seizing open. Never seize the
            // device — the microphone's audio function must be unaffected.
            let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard status == kIOReturnSuccess else {
                throw .openFailed(code: status)
            }
            _isOpen = true
        }
        log.info("Opened \(info.name)")
    }

    public func close() {
        lock.withLock {
            guard _isOpen, !_disconnected else {
                _isOpen = false
                return
            }
            _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            _isOpen = false
        }
        log.info("Closed \(info.name)")
    }

    /// Opens any *allowlisted* interface (including audio-side PIDs) for
    /// read-only input monitoring. Unlike `open()`, this never enables
    /// sending: on non-LED interfaces the transport stays monitor-only.
    public func openForMonitoring() throws(HIDTransportError) {
        guard let known = info.knownDevice else {
            throw .unsupportedDevice(vendorID: info.vendorID, productID: info.productID)
        }
        try lock.withLockTyped { () throws(HIDTransportError) -> Void in
            if _disconnected { throw .deviceDisconnected }
            if !known.supportsLEDControl { _monitorOnly = true }
            guard !_isOpen else { return }
            let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard status == kIOReturnSuccess else {
                throw .openFailed(code: status)
            }
            _isOpen = true
        }
        log.info("Opened \(info.name) for read-only input monitoring")
    }

    public func startInputReportMonitoring(
        _ handler: @escaping @Sendable (HIDInputReport) -> Void
    ) throws(HIDTransportError) {
        try lock.withLockTyped { () throws(HIDTransportError) -> Void in
            if _disconnected { throw .deviceDisconnected }
            guard _isOpen else { throw .deviceNotOpen }
            inputHandler = handler
            if inputBuffer == nil {
                let length = max(info.maxInputReportLength, 64)
                inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
                inputBufferLength = length
            }
            guard let buffer = inputBuffer else { throw .ioError(code: -1) }
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(
                device, buffer, inputBufferLength,
                { context, _, _, _, reportID, report, reportLength in
                    guard let context else { return }
                    let me = Unmanaged<IOKitHIDTransport>.fromOpaque(context)
                        .takeUnretainedValue()
                    let bytes = [UInt8](UnsafeBufferPointer(start: report, count: reportLength))
                    me.deliverInputReport(reportID: UInt8(clamping: reportID), bytes: bytes)
                }, context
            )
            // Input callbacks need the device on a run loop; main is where
            // discovery already lives and the event rate is tiny.
            IOHIDDeviceScheduleWithRunLoop(
                device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
            )
        }
    }

    public func stopInputReportMonitoring() {
        lock.withLock {
            guard inputHandler != nil else { return }
            inputHandler = nil
            if !_disconnected {
                IOHIDDeviceUnscheduleFromRunLoop(
                    device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
                )
            }
        }
    }

    private func deliverInputReport(reportID: UInt8, bytes: [UInt8]) {
        let handler = lock.withLock { inputHandler }
        handler?(HIDInputReport(deviceID: info.id, reportID: reportID, bytes: bytes))
    }

    deinit {
        inputBuffer?.deallocate()
    }

    public func send(_ report: HIDReport, policy: HIDReportPolicy) throws(HIDTransportError) {
        // Monitor-only transports (audio-side interfaces) can never send.
        let monitorOnly = lock.withLock { _monitorOnly }
        if monitorOnly {
            throw .unsupportedDevice(vendorID: info.vendorID, productID: info.productID)
        }
        // Software validation happens before any bytes reach IOKit.
        try policy.validate(report)
        try lock.withLockTyped { () throws(HIDTransportError) -> Void in
            if _disconnected { throw .deviceDisconnected }
            guard _isOpen else { throw .deviceNotOpen }
            let type: IOHIDReportType =
                report.kind == .feature ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput
            // Note: on macOS the payload must NOT include the report ID byte;
            // it is passed separately here (unlike hidapi on Linux).
            let status = report.payload.withUnsafeBufferPointer { buffer -> IOReturn in
                guard let base = buffer.baseAddress else { return kIOReturnBadArgument }
                return IOHIDDeviceSetReport(
                    device,
                    type,
                    CFIndex(report.reportID),
                    base,
                    buffer.count
                )
            }
            guard status == kIOReturnSuccess else {
                throw .ioError(code: status)
            }
        }
    }

    public func getFeatureReport(
        reportID: UInt8,
        maxLength: Int
    ) throws(HIDTransportError) -> [UInt8] {
        try lock.withLockTyped { () throws(HIDTransportError) -> [UInt8] in
            if _disconnected { throw .deviceDisconnected }
            guard _isOpen else { throw .deviceNotOpen }
            guard maxLength > 0 else { throw .emptyPayload }
            var buffer = [UInt8](repeating: 0, count: maxLength)
            var length = CFIndex(maxLength)
            let status = buffer.withUnsafeMutableBufferPointer { ptr -> IOReturn in
                guard let base = ptr.baseAddress else { return kIOReturnBadArgument }
                return IOHIDDeviceGetReport(
                    device,
                    kIOHIDReportTypeFeature,
                    CFIndex(reportID),
                    base,
                    &length
                )
            }
            guard status == kIOReturnSuccess else {
                throw .ioError(code: status)
            }
            return Array(buffer.prefix(Int(length)))
        }
    }

    public func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { disconnectHandler = handler }
    }

    /// Called by `HyperXDeviceManager` when IOKit reports this device removed.
    func markDisconnected() {
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
}
