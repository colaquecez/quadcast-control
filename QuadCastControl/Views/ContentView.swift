import SwiftUI
import QuadCastKit

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    enum Section: String, CaseIterable, Identifiable {
        case status = "Status"
        case lighting = "Lighting"
        case diagnostics = "Diagnostics"
        case developer = "Developer"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .status: "mic"
            case .lighting: "lightbulb"
            case .diagnostics: "stethoscope"
            case .developer: "wrench.and.screwdriver"
            }
        }
    }

    @State private var selection: Section = .status

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch selection {
            case .status: StatusView()
            case .lighting: LightingView()
            case .diagnostics: DiagnosticsView()
            case .developer: DeveloperView()
            }
        }
    }
}

/// Small connected/disconnected pill used in several places.
struct ConnectionBadge: View {
    let connected: Bool

    var body: some View {
        Label(
            connected ? "Connected" : "Not connected",
            systemImage: connected ? "checkmark.circle.fill" : "xmark.circle"
        )
        .foregroundStyle(connected ? .green : .secondary)
        .font(.callout.weight(.medium))
    }
}
