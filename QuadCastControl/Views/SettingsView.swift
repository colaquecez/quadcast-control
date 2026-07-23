import SwiftUI
import ServiceManagement
import QuadCastKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            loginItemError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text(
                    "The QuadCast 2 reverts to full brightness when the app stops, " +
                    "so keep the app running (menu bar) to hold your setting."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let loginItemError {
                    Label(loginItemError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Lighting") {
                Toggle("Lighting control", isOn: Binding(
                    get: { appState.lightingControlEnabled },
                    set: { enabled in
                        if enabled {
                            appState.userEnabledLightingControl()
                        } else {
                            appState.userDisabledLightingControl()
                        }
                    }
                ))
                Text("When off, the app is read-only and sends nothing over USB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Purpose", value: "Local LED control for HyperX QuadCast 2 microphones")
                Text(
                    "This app makes no network connections, collects no telemetry, and " +
                    "talks only to allowlisted HyperX USB HID devices. Preferences are " +
                    "stored in UserDefaults."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.bottom, 8)
    }
}
