import Foundation
import IOKit.hid

/// Discovery events delivered to the app.
public enum DeviceEvent: Sendable, Equatable {
    case connected(HIDDeviceInfo)
    case disconnected(id: UInt64)
}

/// Discovers HyperX HID interfaces with `IOHIDManager` and reacts to
/// hot-plug/unplug.
///
/// Isolation: the manager is `@MainActor` and schedules `IOHIDManager` on the
/// main run loop, so IOKit callbacks arrive on the main thread and can safely
/// touch manager state (`MainActor.assumeIsolated` documents that fact to the
/// compiler). Discovery work is trivial (a handful of interfaces), so the main
/// thread is the simplest correct home for it. Actual report I/O happens on
/// the transports, off the main thread if callers wish.
///
/// Matching strategy: match broadly on the two HyperX vendor IDs so the debug
/// screen can list *every* HyperX interface, then classify against the strict
/// `DeviceAllowlist` for anything that involves opening/writing.
@MainActor
public final class HyperXDeviceManager {
    public private(set) var interfaces: [UInt64: HIDDeviceInfo] = [:]
    /// Live IOKit handles, keyed by registry ID. Not exposed publicly.
    private var devices: [UInt64: IOHIDDevice] = [:]
    private var transports: [UInt64: any HIDTransport & DisconnectMarkable] = [:]

    public var onEvent: ((DeviceEvent) -> Void)?

    private var manager: IOHIDManager?
    private let log: HIDLog

    public init(log: HIDLog = .shared) {
        self.log = log
    }

    /// Starts discovery. Idempotent.
    public func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        // Match on vendor ID only — classification happens in the callback so
        // unknown HyperX products still show up (read-only) in diagnostics.
        let matching = HyperXVendorID.all.map { vid in
            [kIOHIDVendorIDKey: vid] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<HyperXDeviceManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.deviceMatched(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<HyperXDeviceManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.deviceRemoved(device) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Note: we never call IOHIDManagerOpen — opening the *manager* is only
        // needed for manager-level input reports. Individual devices are
        // opened by their transports, and enumeration works without it.
        log.info("Device discovery started (vendors: Kingston 0x0951, HP 0x03F0)")
    }

    public func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
        for transport in transports.values { transport.markDisconnected() }
        transports.removeAll()
        devices.removeAll()
        interfaces.removeAll()
    }

    /// Returns a transport for an interface previously reported as connected.
    /// The transport is created lazily and cached; opening it is the caller's
    /// job (and will fail unless the device is allowlisted).
    ///
    /// The concrete transport depends on the allowlist's `sendPath`: most
    /// devices use HID reports, but the QuadCast 2 needs raw EP0 control
    /// transfers (its HID descriptor declares no writable reports).
    public func transport(for id: UInt64) -> (any HIDTransport)? {
        if let existing = transports[id] { return existing }
        guard let device = devices[id], let info = interfaces[id] else { return nil }
        let transport: any HIDTransport & DisconnectMarkable
        switch info.knownDevice?.sendPath {
        case .controlTransfer(let interfaceNumber):
            transport = USBControlTransport(
                info: info, interfaceNumber: interfaceNumber, log: log
            )
        case .hidReports, nil:
            transport = IOKitHIDTransport(device: device, info: info, log: log)
        }
        transports[id] = transport
        return transport
    }

    /// The first connected interface whose VID/PID is in the allowlist, i.e.
    /// the thing the lighting UI should bind to.
    public var primaryDevice: HIDDeviceInfo? {
        interfaces.values
            .filter { $0.knownDevice != nil }
            .sorted { $0.id < $1.id }
            .first
    }

    // MARK: IOKit callbacks (main thread)

    private func deviceMatched(_ device: IOHIDDevice) {
        let info = Self.makeInfo(for: device)
        guard DeviceAllowlist.isCandidateVendor(info.vendorID) else { return }
        devices[info.id] = device
        interfaces[info.id] = info
        let status = info.knownDevice.map { "known: \($0.model.rawValue)" } ?? "unknown model (read-only)"
        log.info(
            "HID interface attached: \(info.name) " +
            String(format: "VID 0x%04X PID 0x%04X ", info.vendorID, info.productID) +
            String(format: "usagePage 0x%04X usage 0x%02X — %@", info.usagePage, info.usage, status)
        )
        onEvent?(.connected(info))
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let id = Self.registryID(of: device)
        guard interfaces[id] != nil else { return }
        // Tell the transport first so in-flight sends fail cleanly instead of
        // touching a dead IOKit handle.
        transports[id]?.markDisconnected()
        transports[id] = nil
        devices[id] = nil
        interfaces[id] = nil
        log.info("HID interface removed (id \(id))")
        onEvent?(.disconnected(id: id))
    }

    // MARK: Property extraction

    private static func registryID(of device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    static func makeInfo(for device: IOHIDDevice) -> HIDDeviceInfo {
        let descriptor = (IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data)
            .map { [UInt8]($0) }
        return HIDDeviceInfo(
            id: registryID(of: device),
            name: stringProperty(device, kIOHIDProductKey) ?? "Unknown HID device",
            vendorID: intProperty(device, kIOHIDVendorIDKey) ?? 0,
            productID: intProperty(device, kIOHIDProductIDKey) ?? 0,
            usagePage: intProperty(device, kIOHIDPrimaryUsagePageKey) ?? 0,
            usage: intProperty(device, kIOHIDPrimaryUsageKey) ?? 0,
            // The serial is redacted at the source: the full value is read
            // into a local and only the redacted form ever leaves this scope.
            redactedSerial: HIDDeviceInfo.redactSerial(
                stringProperty(device, kIOHIDSerialNumberKey)
            ),
            transportKind: stringProperty(device, kIOHIDTransportKey) ?? "USB",
            maxInputReportLength: intProperty(device, kIOHIDMaxInputReportSizeKey) ?? 0,
            maxOutputReportLength: intProperty(device, kIOHIDMaxOutputReportSizeKey) ?? 0,
            maxFeatureReportLength: intProperty(device, kIOHIDMaxFeatureReportSizeKey) ?? 0,
            reportDescriptor: descriptor
        )
    }
}
