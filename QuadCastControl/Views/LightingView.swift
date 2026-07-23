import SwiftUI
import QuadCastKit

struct LightingView: View {
    @EnvironmentObject private var appState: AppState

    private var hasColor: Bool { appState.capabilities.contains(.staticColor) }
    private var hasBrightness: Bool { appState.capabilities.contains(.brightness) }
    private var hasPersistence: Bool { appState.capabilities.contains(.persistence) }
    private var controlsActive: Bool {
        appState.isConnected && appState.lightingControlEnabled && !appState.capabilities.isEmpty
    }

    var body: some View {
        Form {
            if !appState.isConnected {
                Section {
                    Label("Connect a supported microphone to control its lighting.",
                          systemImage: "mic.slash")
                        .foregroundStyle(.secondary)
                }
            } else if appState.capabilities.isEmpty {
                Section {
                    Label(
                        "This device is recognized, but its LED protocol is not implemented, " +
                        "so the app stays read-only. See PROTOCOL.md for details.",
                        systemImage: "eye"
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                optInSection
                controlsSection
            }

            if let error = appState.lastErrorDescription, appState.isConnected {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Lighting")
    }

    /// Explicit user opt-in before the first byte is ever sent. The protocol
    /// bytes are community-verified (see PROTOCOL.md), but this app still
    /// never transmits until the user chooses to.
    @ViewBuilder private var optInSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { appState.lightingControlEnabled },
                set: { enabled in
                    if enabled {
                        appState.userEnabledLightingControl()
                    } else {
                        appState.userDisabledLightingControl()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lighting control")
                    Text(
                        appState.lightingControlEnabled
                        ? "Sending community-verified commands to the microphone."
                        : "Off: nothing is sent to the microphone. Turning this on sends " +
                          "community-verified LED commands (sources in PROTOCOL.md)."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var controlsSection: some View {
        Section("LED") {
            Toggle("LED on", isOn: Binding(
                get: { appState.ledOn },
                set: { appState.ledToggled($0) }
            ))
            .disabled(!controlsActive)

            if hasBrightness {
                VStack(alignment: .leading) {
                    LabeledContent("Brightness", value: "\(Int(appState.brightnessPercent))%")
                    Slider(
                        value: Binding(
                            get: { appState.brightnessPercent },
                            set: { appState.brightnessChanged($0) }
                        ),
                        in: 0...100,
                        step: 1
                    )
                }
                .disabled(!controlsActive || !appState.ledOn)
            }

            if hasColor {
                ColorPicker(
                    "Static color",
                    selection: Binding(
                        get: { appState.color },
                        set: { appState.colorChanged($0) }
                    ),
                    supportsOpacity: false
                )
                .disabled(!controlsActive || !appState.ledOn)

                LabeledContent("RGB (hex)", value: RGBColor(appState.color).hexString)
                    .font(.body.monospaced())
            } else if appState.isConnected {
                Label(
                    "The QuadCast 2's LEDs are red-only — the hardware has no color " +
                    "control, only brightness.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }

        Section("State") {
            Button("Restore previous lighting") {
                appState.restorePreviousLighting()
            }
            .disabled(!controlsActive)

            Button("Return to device default") {
                // Stopping control lets the microphone fall back to its own
                // onboard lighting (these devices revert once traffic stops).
                appState.userDisabledLightingControl()
            }
            .disabled(!appState.lightingControlEnabled)

            if hasPersistence {
                Button("Save current look to device") {
                    appState.saveToDevice()
                }
                .disabled(!controlsActive)
                Text("Writes the current color to the microphone's flash so it survives " +
                     "unplugging. Use sparingly — flash has limited write cycles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
