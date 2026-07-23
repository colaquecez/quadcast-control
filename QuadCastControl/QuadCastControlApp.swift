import SwiftUI
import QuadCastKit

/// App entry point: one main window plus a menu bar extra. The main window
/// can be closed at any time — the menu bar extra keeps lighting control
/// available and the refresh loop alive.
@main
struct QuadCastControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("QuadCast Control", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 640, minHeight: 440)
        }
        .defaultSize(width: 760, height: 520)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isConnected ? "mic.fill" : "mic.slash")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

/// Keeps the app alive (and the keep-alive refresh loop running) when the
/// last window closes; the menu bar extra remains the way back in.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
