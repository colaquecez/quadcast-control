import Foundation
import CQuadCastUSB

/// Transport that delivers reports as raw HID class control transfers on
/// endpoint 0 (SET_REPORT / GET_REPORT), bypassing the HID report API.
///
/// Needed for the QuadCast 2: its LED controller *accepts* 64-byte feature
/// reports in firmware, but its HID report descriptor does not declare any
/// writable report, so `IOHIDDeviceSetReport` fails (pipe stall,
/// 0xE0005000). The community protocol — and NGENUITY itself — sends the
/// control transfer directly. Verified working on real hardware via
/// IOUSBLib, with no kernel-driver detach and no effect on audio.
///
/// The `info` still describes the device's HID interface (for diagnostics);
/// only the byte delivery differs from `IOKitHIDTransport`.
public final class USBControlTransport: HIDTransport, DisconnectMarkable, @unchecked Sendable {
    public let info: HIDDeviceInfo
    /// USB interface number the control requests target (wIndex).
    private let interfaceNumber: UInt16

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var _disconnected = false
    private var disconnectHandler: (@Sendable () -> Void)?
    private let log: HIDLog

    public init(info: HIDDeviceInfo, interfaceNumber: UInt16 = 0, log: HIDLog = .shared) {
        self.info = info
        self.interfaceNumber = interfaceNumber
        self.log = log
    }

    deinit {
        if let handle { qcusb_close(handle) }
    }

    public var isOpen: Bool { lock.withLock { handle != nil } }

    public func open() throws(HIDTransportError) {
        guard info.knownDevice?.supportsLEDControl == true else {
            throw .unsupportedDevice(vendorID: info.vendorID, productID: info.productID)
        }
        try lock.withLockTyped { () throws(HIDTransportError) -> Void in
            if _disconnected { throw .deviceDisconnected }
            guard handle == nil else { return }
            guard let opened = qcusb_open(Int32(info.vendorID), Int32(info.productID)) else {
                throw .openFailed(code: -1)
            }
            handle = opened
        }
        log.info("Opened \(info.name) (raw control-transfer path, interface \(interfaceNumber))")
    }

    public func close() {
        lock.withLock {
            if let handle { qcusb_close(handle) }
            handle = nil
        }
    }

    public func send(_ report: HIDReport, policy: HIDReportPolicy) throws(HIDTransportError) {
        try policy.validate(report)
        try lock.withLockTyped { () throws(HIDTransportError) -> Void in
            if _disconnected { throw .deviceDisconnected }
            guard let handle else { throw .deviceNotOpen }
            // wValue = (report type << 8) | report ID, per the HID spec.
            let typeByte: UInt16 = report.kind == .feature ? 0x0300 : 0x0200
            let wValue = typeByte | UInt16(report.reportID)
            let status = report.payload.withUnsafeBufferPointer { buffer in
                qcusb_set_report(
                    handle, wValue, interfaceNumber,
                    buffer.baseAddress, UInt16(buffer.count)
                )
            }
            guard status == 0 else { throw .ioError(code: status) }
        }
    }

    public func getFeatureReport(
        reportID: UInt8,
        maxLength: Int
    ) throws(HIDTransportError) -> [UInt8] {
        try lock.withLockTyped { () throws(HIDTransportError) -> [UInt8] in
            if _disconnected { throw .deviceDisconnected }
            guard let handle else { throw .deviceNotOpen }
            guard maxLength > 0 else { throw .emptyPayload }
            var buffer = [UInt8](repeating: 0, count: maxLength)
            var received: UInt32 = 0
            let wValue = 0x0300 | UInt16(reportID)
            let status = buffer.withUnsafeMutableBufferPointer { ptr in
                qcusb_get_report(
                    handle, wValue, interfaceNumber,
                    ptr.baseAddress, UInt16(ptr.count), &received
                )
            }
            guard status == 0 else { throw .ioError(code: status) }
            return Array(buffer.prefix(Int(received)))
        }
    }

    public func startInputReportMonitoring(
        _ handler: @escaping @Sendable (HIDInputReport) -> Void
    ) throws(HIDTransportError) {
        // Raw EP0 control transfers have no interrupt-IN event stream here;
        // input monitoring goes through the HID interface instead (the
        // device manager creates a separate monitoring transport for that).
        throw .monitoringNotSupported
    }

    public func stopInputReportMonitoring() {}

    public func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { disconnectHandler = handler }
    }

    /// Called by `HyperXDeviceManager` when the device's HID interface node
    /// disappears (the USB device is gone with it).
    func markDisconnected() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !_disconnected else { return nil }
            _disconnected = true
            if let handle { qcusb_close(handle) }
            handle = nil
            let h = disconnectHandler
            disconnectHandler = nil
            return h
        }
        handler?()
    }
}
