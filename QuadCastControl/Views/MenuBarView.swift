import SwiftUI
import QuadCastKit

/// Compact controls in the menu bar extra. The app remains fully functional
/// with the main window closed.
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(appState.primaryDevice?.knownDevice?.model.rawValue ?? "QuadCast")
                    .font(.headline)
                Spacer()
                ConnectionBadge(connected: appState.isConnected)
            }

            if appState.isConnected && !appState.capabilities.isEmpty {
                if appState.lightingControlEnabled {
                    Toggle("LED", isOn: Binding(
                        get: { appState.ledOn },
                        set: { appState.ledToggled($0) }
                    ))
                    .toggleStyle(.switch)

                    if appState.capabilities.contains(.brightness) {
                        HStack {
                            Image(systemName: "sun.min")
                            Slider(
                                value: Binding(
                                    get: { appState.brightnessPercent },
                                    set: { appState.brightnessChanged($0) }
                                ),
                                in: 0...100
                            )
                            Image(systemName: "sun.max")
                        }
                        .disabled(!appState.ledOn)
                    }

                    if appState.capabilities.contains(.staticColor) {
                        ColorPicker("Color", selection: Binding(
                            get: { appState.color },
                            set: { appState.colorChanged($0) }
                        ), supportsOpacity: false)
                        .disabled(!appState.ledOn)
                    }
                } else {
                    Button("Enable lighting control") {
                        appState.userEnabledLightingControl()
                    }
                    Text("Nothing is sent to the microphone until enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if appState.isConnected {
                Text("LED control not available for this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Open QuadCast Control") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                settingsButton
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 280)
    }

    /// As a menu-bar-only app (LSUIElement) there is no app menu, so Settings
    /// (with "Start at login") must be reachable from here.
    @ViewBuilder private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Text("Settings…")
            }
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })
        } else {
            Button("Settings…") {
                // Legacy selector for macOS 13 (SettingsLink is 14+).
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
