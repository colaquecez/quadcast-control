import SwiftUI
import QuadCastKit

/// Developer tools for safe reverse engineering.
///
/// - Packet Diff analyzes *text* only and never touches the device.
/// - Manual report sending is compiled into DEBUG builds exclusively, is off
///   until developer mode is toggled, and requires a per-send confirmation.
struct DeveloperView: View {
    var body: some View {
        Form {
            PacketDiffSection()
            #if DEBUG
            ManualSendSection()
            #else
            Section("Manual report sending") {
                Label(
                    "Disabled in release builds. Build the app in the Debug " +
                    "configuration to use the manual send tool.",
                    systemImage: "lock"
                )
                .foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Developer")
    }
}

// MARK: - Packet diff

private struct PacketDiffSection: View {
    @State private var beforeHex = ""
    @State private var afterHex = ""
    @State private var result: PacketDiff.Result?
    @State private var parseError: String?

    var body: some View {
        Section("Packet diff") {
            Text(
                "Paste two sanitized HID payload dumps (hex) captured before and " +
                "after changing one setting — for example from a Wireshark/USBPcap " +
                "capture of NGENUITY. Changed bytes are highlighted with possible " +
                "interpretations. Nothing here is ever sent to the device."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField("Before (e.g. 44 02 00 00 C9 00 76 …)", text: $beforeHex, axis: .vertical)
                .font(.body.monospaced())
                .lineLimit(2...4)
            TextField("After", text: $afterHex, axis: .vertical)
                .font(.body.monospaced())
                .lineLimit(2...4)

            Button("Compare") {
                parseError = nil
                result = nil
                do {
                    result = try PacketDiff.compare(beforeHex: beforeHex, afterHex: afterHex)
                } catch let error as PacketDiff.ParseError {
                    parseError = "Could not parse the \(errorWhich(error)) packet as hex."
                } catch {
                    parseError = "Could not parse the input as hex."
                }
            }
            .disabled(beforeHex.isEmpty || afterHex.isEmpty)

            if let parseError {
                Label(parseError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if let result {
                if result.isIdentical {
                    Label("Packets are identical.", systemImage: "equal.circle")
                } else {
                    diffTable(result)
                    ForEach(Array(result.hypotheses.enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "questionmark.circle")
                            .font(.callout)
                    }
                    Text("These are hypotheses for a human to verify — the app never acts on them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func errorWhich(_ error: PacketDiff.ParseError) -> String {
        if case .invalidHex(let which) = error { return which }
        return "input"
    }

    private func diffTable(_ result: PacketDiff.Result) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 2) {
            GridRow {
                Text("Offset").bold()
                Text("Before").bold()
                Text("After").bold()
            }
            ForEach(result.diffs) { diff in
                GridRow {
                    Text(String(format: "%d (0x%02X)", diff.offset, diff.offset))
                    Text(diff.before.map { String(format: "0x%02X", $0) } ?? "—")
                    Text(diff.after.map { String(format: "0x%02X", $0) } ?? "—")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.callout.monospaced())
    }
}

// MARK: - Manual send (DEBUG builds only)

#if DEBUG
private struct ManualSendSection: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("developerModeEnabled") private var developerModeEnabled = false
    @State private var reportHex = ""
    @State private var useFeatureReport = true
    @State private var reportID = 0
    @State private var confirming = false
    @State private var outcome: String?

    var body: some View {
        Section("Manual report sending (DEBUG build)") {
            Toggle(isOn: $developerModeEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Developer mode")
                    Text("Allows sending a manually entered report to the connected device. " +
                         "Captured commands are never replayed automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if developerModeEnabled {
                Picker("Report type", selection: $useFeatureReport) {
                    Text("Feature").tag(true)
                    Text("Output").tag(false)
                }
                Stepper("Report ID: \(reportID)", value: $reportID, in: 0...255)
                TextField("Payload hex (report ID excluded)", text: $reportHex, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(2...4)

                Button("Send…") { confirming = true }
                    .disabled(!appState.isConnected || HexDump.parse(reportHex) == nil)
                    .confirmationDialog(
                        "Send this report to the microphone?",
                        isPresented: $confirming
                    ) {
                        Button("Send", role: .destructive) { send() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(
                            "\(useFeatureReport ? "Feature" : "Output") report, ID \(reportID), " +
                            "\(HexDump.parse(reportHex)?.count ?? 0) bytes. Sending unknown " +
                            "commands can put the device in an unexpected state until replug."
                        )
                    }

                if let outcome {
                    Text(outcome)
                        .font(.callout.monospaced())
                }
            }
        }
    }

    private func send() {
        guard let payload = HexDump.parse(reportHex) else { return }
        let report = HIDReport(
            kind: useFeatureReport ? .feature : .output,
            reportID: UInt8(clamping: reportID),
            payload: payload
        )
        guard let device = appState.primaryDevice,
              let transport = appState.deviceManager.transport(for: device.id) else {
            outcome = "No device transport available."
            return
        }
        // Manual sends still respect the device's max lengths, but use a
        // permissive ID policy — that is the point of the tool. DEBUG only.
        let policy = HIDReportPolicy(
            allowedReportIDs: [
                .feature: Set(0...255),
                .output: Set(0...255),
            ],
            maxPayloadLength: [
                .feature: max(device.maxFeatureReportLength, 64),
                .output: max(device.maxOutputReportLength, 64),
            ]
        )
        do {
            try transport.send(report, policy: policy)
            outcome = "Sent: \(report.hexDescription)"
        } catch {
            outcome = "Failed: \(String(describing: error))"
        }
        HIDLog.shared.info("Manual send by developer: \(report.hexDescription)")
    }
}
#endif
