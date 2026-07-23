import SwiftUI
import QuadCastKit

struct StatusView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.statusMessage)
                            .font(.title3.weight(.semibold))
                        if let device = appState.primaryDevice {
                            Text(device.name)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    ConnectionBadge(connected: appState.isConnected)
                }
                .padding(.vertical, 4)
            }

            if let device = appState.primaryDevice {
                Section("Device") {
                    LabeledContent("Name", value: device.name)
                    LabeledContent("Model", value: device.knownDevice?.model.rawValue ?? "Unknown")
                    LabeledContent("Vendor ID", value: hex4(device.vendorID))
                    LabeledContent("Product ID", value: hex4(device.productID))
                    LabeledContent("Role", value: device.knownDevice?.role.rawValue ?? "—")
                    if let serial = device.redactedSerial {
                        LabeledContent("Serial (redacted)", value: serial)
                    }
                    LabeledContent("Transport", value: device.transportKind)
                }

                Section("Lighting capabilities") {
                    if appState.capabilities.isEmpty {
                        Text("No LED control available for this device.")
                            .foregroundStyle(.secondary)
                    } else {
                        capabilityRow("Power on/off", .onOff)
                        capabilityRow("Brightness", .brightness)
                        capabilityRow("Static color", .staticColor)
                        capabilityRow("Save to device", .persistence)
                    }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect a HyperX QuadCast 2 or QuadCast 2 S via USB.")
                        Text(
                            "The app watches for HyperX devices (vendor IDs 0x0951 and 0x03F0) " +
                            "and binds automatically when a supported LED controller appears."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let error = appState.lastErrorDescription {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Status")
    }

    private func capabilityRow(_ label: String, _ capability: LightingCapabilities) -> some View {
        LabeledContent(label) {
            Image(systemName: appState.capabilities.contains(capability)
                  ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(appState.capabilities.contains(capability) ? .green : .secondary)
        }
    }
}

func hex4(_ value: Int) -> String {
    String(format: "0x%04X", value)
}
