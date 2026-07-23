import Foundation

/// The lighting configuration the user has asked for.
public struct LightingState: Sendable, Equatable {
    public var isOn: Bool
    public var brightness: Brightness
    public var color: RGBColor

    public init(
        isOn: Bool = true,
        brightness: Brightness = .full,
        color: RGBColor = .white
    ) {
        self.isOn = isOn
        self.brightness = brightness
        self.color = color
    }
}

/// Errors surfaced to the UI by the lighting service.
public enum LightingServiceError: Error, Equatable, Sendable {
    case noDeviceAttached
    case protocolUnavailable(HyperXModel?)
    /// LED control exists but the user has not opted in yet.
    case controlNotEnabled
    case transport(HIDTransportError)
    case encoding(ProtocolError)
}

/// Owns the "what the LEDs should look like" state and pushes it to the
/// device through a protocol encoder + transport.
///
/// Design notes:
/// - It is an actor: all mutation is serialized, and the debounce/refresh
///   tasks can be cancelled/replaced without locks.
/// - Slider changes call `setBrightness`/`setColor` at UI rate; the service
///   coalesces them and sends at most one update per `debounceInterval`, so
///   the USB device is never flooded.
/// - `controlEnabled` is an explicit safety latch: even for encoders whose
///   packets are community-verified, nothing is transmitted until the user
///   has opted in once (the app persists that choice).
/// - Encoders whose devices need keep-alive traffic get a refresh loop at
///   the encoder's `refreshInterval`; stopping control stops the loop and the
///   device falls back to its own onboard lighting.
public actor LightingService {
    public private(set) var state = LightingState()
    public private(set) var lastError: LightingServiceError?
    /// Count of reports actually handed to the transport (diagnostics/tests).
    public private(set) var sendCount = 0
    /// The user's explicit opt-in to send lighting commands.
    public private(set) var controlEnabled = false

    private var transport: (any HIDTransport)?
    private var encoder: (any LightingProtocolEncoding)?
    private let log: HIDLog
    private let debounceInterval: Duration
    private var pendingFlush: Task<Void, Never>?
    private var refreshLoop: Task<Void, Never>?
    /// State snapshot taken when a device attaches, restored by
    /// `restorePrevious()`.
    private var stateAtAttach: LightingState?

    public init(
        debounceInterval: Duration = .milliseconds(80),
        log: HIDLog = .shared
    ) {
        self.debounceInterval = debounceInterval
        self.log = log
    }

    // MARK: Device lifecycle

    /// Attaches a transport for a discovered, allowlisted device.
    /// Throws if the device is not in the allowlist; a missing encoder is not
    /// an error (the app stays read-only for that device).
    public func attach(
        transport: any HIDTransport,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {
        guard let known = transport.info.knownDevice, known.supportsLEDControl else {
            throw LightingServiceError.transport(
                .unsupportedDevice(
                    vendorID: transport.info.vendorID,
                    productID: transport.info.productID
                )
            )
        }
        do {
            try transport.open()
        } catch {
            throw LightingServiceError.transport(error)
        }
        transport.setDisconnectHandler { [weak self] in
            Task { [weak self] in await self?.handleDisconnect() }
            onDisconnect()
        }
        self.transport = transport
        self.encoder = ProtocolRegistry.encoder(for: known)
        self.stateAtAttach = state
        self.lastError = nil
        log.info("Attached \(transport.info.name) (\(known.model.rawValue))")
    }

    public func detach() {
        stopTasks()
        transport?.close()
        transport = nil
        encoder = nil
        stateAtAttach = nil
    }

    public var isAttached: Bool { transport != nil }

    /// True when the attached device has a protocol encoder.
    public var hasEncoder: Bool { encoder != nil }

    public var capabilities: LightingCapabilities {
        encoder?.capabilities ?? []
    }

    private func handleDisconnect() {
        // The device is gone: drop the transport quietly. State is kept so the
        // same look is re-applied on reconnect.
        stopTasks()
        transport = nil
        encoder = nil
        lastError = .noDeviceAttached
        log.warning("Device disconnected")
    }

    private func stopTasks() {
        pendingFlush?.cancel()
        pendingFlush = nil
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    // MARK: Control latch

    /// User opt-in. Starting control applies the current state immediately
    /// and starts the device's keep-alive refresh loop if it needs one.
    public func enableControl() async {
        controlEnabled = true
        await flushNow()
        startRefreshLoopIfNeeded()
    }

    /// Stops sending anything. Devices with keep-alive semantics revert to
    /// their own onboard lighting shortly after (that is also how "restore
    /// device default" is implemented for them).
    public func disableControl() {
        controlEnabled = false
        stopTasks()
        log.info("Lighting control stopped; device returns to onboard lighting")
    }

    // MARK: User intents (debounced where high-frequency)

    public func setPower(on: Bool) async {
        state.isOn = on
        await flushNow()
    }

    public func setBrightness(_ brightness: Brightness) {
        state.brightness = brightness
        scheduleFlush()
    }

    public func setColor(_ color: RGBColor) {
        state.color = color
        scheduleFlush()
    }

    /// Restores the lighting state captured when the device attached.
    public func restorePrevious() async {
        if let previous = stateAtAttach {
            state = previous
        }
        await flushNow()
    }

    /// Persists the current look to device flash, when supported.
    public func saveToDevice() async {
        guard let encoder, controlEnabled else {
            lastError = controlEnabled ? .protocolUnavailable(nil) : .controlNotEnabled
            return
        }
        do {
            let packets = try encoder.save(state)
            await send(packets: packets)
        } catch {
            lastError = .encoding(error)
        }
    }

    // MARK: Sending

    private func scheduleFlush() {
        pendingFlush?.cancel()
        pendingFlush = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            await self.flushNow()
        }
    }

    /// Pushes the current state to the device now.
    public func flushNow() async {
        pendingFlush?.cancel()
        pendingFlush = nil
        guard let encoder else {
            if transport == nil {
                lastError = .noDeviceAttached
            } else {
                lastError = .protocolUnavailable(transport?.info.knownDevice?.model)
            }
            return
        }
        guard controlEnabled else {
            lastError = .controlNotEnabled
            return
        }
        do {
            let packets = try encoder.apply(state)
            await send(packets: packets)
        } catch {
            lastError = .encoding(error)
        }
        startRefreshLoopIfNeeded()
    }

    private func startRefreshLoopIfNeeded() {
        guard refreshLoop == nil,
              controlEnabled,
              let interval = encoder?.refreshInterval else { return }
        refreshLoop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self.refreshTick()
            }
        }
    }

    private func refreshTick() async {
        guard controlEnabled, let encoder, transport != nil else {
            refreshLoop?.cancel()
            refreshLoop = nil
            return
        }
        // Skip a tick while a debounced flush is pending — the flush will
        // send fresher state momentarily.
        guard pendingFlush == nil else { return }
        if let packets = try? encoder.refresh(state) {
            await send(packets: packets, quiet: true)
        }
    }

    private func send(packets: [EncodedCommand], quiet: Bool = false) async {
        guard let transport else {
            lastError = .noDeviceAttached
            return
        }
        guard let encoder else {
            lastError = .protocolUnavailable(transport.info.knownDevice?.model)
            return
        }
        for packet in packets {
            // Defense in depth: even a bug in an encoder cannot ship
            // unverified bytes — the verification flag is checked per packet.
            guard packet.isVerified else {
                lastError = .encoding(.commandNotYetVerified(model: encoder.model))
                log.warning("Refusing to send unverified packet")
                return
            }
            do {
                try transport.send(packet.report, policy: encoder.reportPolicy)
                sendCount += 1
                lastError = nil
                if !quiet {
                    log.logSend(packet.report, deviceName: transport.info.name)
                }
            } catch {
                lastError = .transport(error)
                if case .deviceDisconnected = error {
                    // handleDisconnect will tidy up via the transport handler.
                    return
                }
                log.error("Send failed: \(String(describing: error))")
                return
            }
            if packet.postDelay > .zero {
                try? await Task.sleep(for: packet.postDelay)
            }
        }
    }

    // MARK: Test/diagnostic support

    /// Waits until any pending debounced flush has completed. Test helper.
    public func settle() async {
        while let pending = pendingFlush {
            _ = await pending.value
            // flushNow() clears pendingFlush; if a newer flush replaced it,
            // the loop simply awaits that one too.
            await Task.yield()
        }
    }

    /// Swaps the encoder — used by unit tests to exercise the send path with
    /// fake encoders without going through `ProtocolRegistry`.
    public func overrideEncoderForTesting(_ encoder: any LightingProtocolEncoding) {
        self.encoder = encoder
    }
}
