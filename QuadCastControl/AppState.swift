import SwiftUI
import Combine
import QuadCastKit

/// Main-actor view model bridging the device manager and lighting service to
/// SwiftUI. All UI state lives here; all HID work happens in QuadCastKit.
@MainActor
final class AppState: ObservableObject {
    // MARK: Published UI state

    @Published private(set) var interfaces: [HIDDeviceInfo] = []
    @Published private(set) var primaryDevice: HIDDeviceInfo?
    @Published private(set) var isConnected = false
    @Published private(set) var statusMessage = "Searching for HyperX microphones…"
    @Published private(set) var lastErrorDescription: String?
    @Published private(set) var capabilities: LightingCapabilities = []
    @Published private(set) var logEntries: [HIDLogEntry] = []

    /// Mirrors of the lighting state, bound to UI controls.
    @Published var ledOn = true
    @Published var brightnessPercent = 100.0
    @Published var color = Color.white

    /// Whether the user has opted in to sending lighting commands.
    @AppStorage("lightingControlEnabled") var lightingControlEnabled = false
    @AppStorage("lastColorHex") private var lastColorHex = "FFFFFF"
    @AppStorage("lastBrightness") private var lastBrightness = 100
    @AppStorage("lastLedOn") private var lastLedOn = true

    // MARK: Services (injected for testability/previews)

    let deviceManager: HyperXDeviceManager
    let lightingService: LightingService
    private let log: HIDLog

    init(
        deviceManager: HyperXDeviceManager? = nil,
        lightingService: LightingService? = nil,
        log: HIDLog = .shared
    ) {
        self.deviceManager = deviceManager ?? HyperXDeviceManager(log: log)
        self.lightingService = lightingService ?? LightingService(log: log)
        self.log = log

        restorePreferences()
        wireLog()
        wireDiscovery()
        self.deviceManager.start()
    }

    // MARK: Wiring

    private func wireDiscovery() {
        deviceManager.onEvent = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                await self.handle(event: event)
            }
        }
    }

    private func wireLog() {
        logEntries = log.entries
        log.onAppend = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logEntries = self.log.entries
            }
        }
    }

    private func handle(event: DeviceEvent) async {
        interfaces = deviceManager.interfaces.values.sorted { $0.id < $1.id }

        switch event {
        case .connected(let info):
            await bindPrimaryIfNeeded(justConnected: info)
        case .disconnected:
            if let primary = primaryDevice, deviceManager.interfaces[primary.id] == nil {
                primaryDevice = nil
                isConnected = false
                statusMessage = "Microphone disconnected"
                capabilities = []
                await lightingService.detach()
            }
        }
    }

    /// Guards against concurrent bind attempts when several interfaces of the
    /// same device appear in one burst (attach suspends mid-flight).
    private var isBinding = false

    /// Chooses the LED-controller interface to bind to: allowlisted, LED
    /// capable, and on the protocol's preferred usage page when specified.
    private func bindPrimaryIfNeeded(justConnected: HIDDeviceInfo) async {
        guard primaryDevice == nil, !isBinding else { return }
        isBinding = true
        defer { isBinding = false }
        let candidates = interfaces.filter { info in
            guard let known = info.knownDevice, known.supportsLEDControl else { return false }
            if let page = known.preferredUsagePage, info.usagePage != page { return false }
            return true
        }
        guard let chosen = candidates.first, let known = chosen.knownDevice else {
            if justConnected.knownDevice != nil {
                statusMessage = "\(justConnected.name) detected (no LED interface bound)"
            }
            return
        }
        guard let transport = deviceManager.transport(for: chosen.id) else { return }
        do {
            try await lightingService.attach(transport: transport, onDisconnect: {})
            primaryDevice = chosen
            isConnected = true
            capabilities = await lightingService.capabilities
            statusMessage = "\(known.model.rawValue) connected"
            if lightingControlEnabled {
                await pushFullState()
                await lightingService.enableControl()
            }
        } catch {
            statusMessage = "Found \(chosen.name) but could not open it"
            lastErrorDescription = String(describing: error)
            log.error("Attach failed: \(String(describing: error))")
        }
    }

    // MARK: User intents

    func userEnabledLightingControl() {
        lightingControlEnabled = true
        Task {
            await pushFullState()
            await lightingService.enableControl()
            await refreshErrorState()
        }
    }

    func userDisabledLightingControl() {
        lightingControlEnabled = false
        Task { await lightingService.disableControl() }
    }

    func ledToggled(_ on: Bool) {
        ledOn = on
        lastLedOn = on
        Task {
            await lightingService.setPower(on: on)
            await refreshErrorState()
        }
    }

    func brightnessChanged(_ percent: Double) {
        brightnessPercent = percent
        lastBrightness = Int(percent)
        Task {
            // Debouncing happens inside the service; forwarding every slider
            // tick here is fine and keeps the UI responsive.
            await lightingService.setBrightness(Brightness(percent: Int(percent)))
        }
    }

    func colorChanged(_ newColor: Color) {
        color = newColor
        let rgb = RGBColor(newColor)
        lastColorHex = rgb.hexString
        Task {
            await lightingService.setColor(rgb)
        }
    }

    func restorePreviousLighting() {
        Task {
            await lightingService.restorePrevious()
            let state = await lightingService.state
            applyToUI(state)
            await refreshErrorState()
        }
    }

    func saveToDevice() {
        Task {
            await lightingService.saveToDevice()
            await refreshErrorState()
        }
    }

    // MARK: Helpers

    private func pushFullState() async {
        await lightingService.setPower(on: ledOn)
        await lightingService.setBrightness(Brightness(percent: Int(brightnessPercent)))
        await lightingService.setColor(RGBColor(color))
        await lightingService.flushNow()
    }

    private func refreshErrorState() async {
        if let error = await lightingService.lastError {
            lastErrorDescription = Self.describe(error)
        } else {
            lastErrorDescription = nil
        }
    }

    private func applyToUI(_ state: LightingState) {
        ledOn = state.isOn
        brightnessPercent = Double(state.brightness.percent)
        color = Color(
            red: Double(state.color.red) / 255.0,
            green: Double(state.color.green) / 255.0,
            blue: Double(state.color.blue) / 255.0
        )
    }

    private func restorePreferences() {
        ledOn = lastLedOn
        brightnessPercent = Double(lastBrightness)
        if let rgb = RGBColor(hexString: lastColorHex) {
            color = Color(
                red: Double(rgb.red) / 255.0,
                green: Double(rgb.green) / 255.0,
                blue: Double(rgb.blue) / 255.0
            )
        }
    }

    static func describe(_ error: LightingServiceError) -> String {
        switch error {
        case .noDeviceAttached:
            return "No microphone attached."
        case .protocolUnavailable(let model):
            if let model {
                return "The \(model.rawValue) is recognized, but its LED protocol is not implemented in this app."
            }
            return "This device's LED protocol is not implemented."
        case .controlNotEnabled:
            return "Lighting control is off. Enable it to send commands to the microphone."
        case .transport(let e):
            return "USB communication error: \(String(describing: e))"
        case .encoding(.unsupportedByHardware(let model, let what)):
            return "The \(model.rawValue) does not support \(what)."
        case .encoding(let e):
            return "Protocol error: \(String(describing: e))"
        }
    }
}

extension QuadCastKit.RGBColor {
    /// Converts a SwiftUI color to the wire RGB (sRGB, clamped).
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            unitRed: ns.redComponent,
            unitGreen: ns.greenComponent,
            unitBlue: ns.blueComponent
        )
    }
}
