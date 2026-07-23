import SwiftUI
import QuadCastKit

/// Read-only debug screen: every HyperX HID interface, its identifiers, and
/// (on demand) its report descriptor. No system-wide device information is
/// shown — only HyperX-vendor interfaces, with serials redacted.
struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var expandedDescriptor: UInt64?

    var body: some View {
        Form {
            Section("HyperX HID interfaces (\(appState.interfaces.count))") {
                if appState.interfaces.isEmpty {
                    Text("No HyperX HID interfaces found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.interfaces) { interface in
                        interfaceRow(interface)
                    }
                }
            }

            Section("Log") {
                LogView(entries: appState.logEntries)
                    .frame(minHeight: 180)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
    }

    @ViewBuilder private func interfaceRow(_ interface: HIDDeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(interface.name).font(.headline)
                Spacer()
                if let known = interface.knownDevice {
                    Text("\(known.model.rawValue) · \(known.role.rawValue)")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                } else {
                    Text("Unrecognized (read-only)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                GridRow {
                    Text("VID \(hex4(interface.vendorID))")
                    Text("PID \(hex4(interface.productID))")
                    Text(String(format: "Usage 0x%04X:0x%02X", interface.usagePage, interface.usage))
                }
                GridRow {
                    Text("In \(interface.maxInputReportLength)B")
                    Text("Out \(interface.maxOutputReportLength)B")
                    Text("Feature \(interface.maxFeatureReportLength)B")
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

            if let descriptor = interface.reportDescriptor {
                DisclosureGroup(
                    "Report descriptor (\(descriptor.count) bytes)",
                    isExpanded: Binding(
                        get: { expandedDescriptor == interface.id },
                        set: { expandedDescriptor = $0 ? interface.id : nil }
                    )
                ) {
                    ScrollView(.horizontal) {
                        Text(HexDump.multiline(descriptor))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

struct LogView: View {
    let entries: [HIDLogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        Text("\(entry.date.formatted(date: .omitted, time: .standard))  \(entry.message)")
                            .font(.caption.monospaced())
                            .foregroundStyle(color(for: entry.level))
                            .textSelection(.enabled)
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: entries.count) { _ in
                if let last = entries.last { proxy.scrollTo(last.id) }
            }
        }
    }

    private func color(for level: HIDLogEntry.Level) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}
