import Foundation

/// Offline packet-comparison helper for safe reverse engineering.
///
/// The developer captures HID traffic externally (e.g. NGENUITY on Windows via
/// USBPcap), changes exactly one setting between captures, pastes the two
/// sanitized hex dumps here, and reads which bytes moved. This tool only ever
/// analyzes text — it never touches a device and never replays anything.
public enum PacketDiff {
    public struct ByteDiff: Sendable, Equatable, Identifiable {
        public var id: Int { offset }
        public let offset: Int
        /// nil when the packet lacks this offset (length mismatch region).
        public let before: UInt8?
        public let after: UInt8?
    }

    public struct Result: Sendable, Equatable {
        public let before: [UInt8]
        public let after: [UInt8]
        public let diffs: [ByteDiff]
        public let hypotheses: [String]

        public var isIdentical: Bool { diffs.isEmpty }
    }

    public enum ParseError: Error, Equatable, Sendable {
        case invalidHex(which: String)
    }

    /// Parses two sanitized hex strings and diffs them.
    public static func compare(
        beforeHex: String,
        afterHex: String
    ) throws(ParseError) -> Result {
        guard let before = HexDump.parse(beforeHex) else {
            throw .invalidHex(which: "before")
        }
        guard let after = HexDump.parse(afterHex) else {
            throw .invalidHex(which: "after")
        }
        let diffs = diff(before, after)
        return Result(
            before: before,
            after: after,
            diffs: diffs,
            hypotheses: hypothesize(diffs: diffs, before: before, after: after)
        )
    }

    static func diff(_ a: [UInt8], _ b: [UInt8]) -> [ByteDiff] {
        (0..<Swift.max(a.count, b.count)).compactMap { i in
            let x = i < a.count ? a[i] : nil
            let y = i < b.count ? b[i] : nil
            return x == y ? nil : ByteDiff(offset: i, before: x, after: y)
        }
    }

    /// Heuristic interpretations of a diff. These are *suggestions to a human*,
    /// clearly phrased as possibilities — never fed back into the device.
    static func hypothesize(
        diffs: [ByteDiff],
        before: [UInt8],
        after: [UInt8]
    ) -> [String] {
        var notes: [String] = []
        if before.count != after.count {
            notes.append(
                "Packet lengths differ (\(before.count) vs \(after.count)) — "
                    + "these may be different commands, not a field change."
            )
        }
        guard !diffs.isEmpty else {
            notes.append("Packets are identical.")
            return notes
        }
        // Runs of consecutive changed offsets.
        var runs: [[ByteDiff]] = []
        for d in diffs {
            if var last = runs.last, let prev = last.last, prev.offset == d.offset - 1 {
                last.append(d)
                runs[runs.count - 1] = last
            } else {
                runs.append([d])
            }
        }
        for run in runs {
            let start = run[0].offset
            switch run.count {
            case 1:
                let d = run[0]
                if let b = d.before, let a = d.after {
                    if (b == 0x00 && a != 0x00) || (b != 0x00 && a == 0x00) {
                        notes.append(
                            "Offset \(start): single byte toggled "
                                + "(0x\(String(format: "%02X", b)) → 0x\(String(format: "%02X", a))) "
                                + "— possible on/off flag or mode selector."
                        )
                    } else {
                        notes.append(
                            "Offset \(start): single byte changed "
                                + "(0x\(String(format: "%02X", b)) → 0x\(String(format: "%02X", a))) "
                                + "— possible scalar field (brightness, speed, mode index)."
                        )
                    }
                }
            case 3:
                notes.append(
                    "Offsets \(start)–\(start + 2): three consecutive bytes changed — "
                        + "possible RGB color triplet (byte order unknown: could be RGB, GRB, or BGR)."
                )
            case 4:
                notes.append(
                    "Offsets \(start)–\(start + 3): four consecutive bytes changed — "
                        + "possible RGBW / RGB+brightness group or a 32-bit field."
                )
            default:
                notes.append(
                    "Offsets \(start)–\(start + run.count - 1): \(run.count) consecutive "
                        + "bytes changed — possible multi-byte field or payload block."
                )
            }
        }
        if let lastDiff = diffs.last,
            lastDiff.offset == Swift.max(before.count, after.count) - 1,
            diffs.count > 1
        {
            notes.append(
                "The final byte also changed — many HID protocols put a checksum "
                    + "or sequence counter in the last byte."
            )
        }
        return notes
    }
}
