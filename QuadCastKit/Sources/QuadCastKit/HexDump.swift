import Foundation

/// Hex formatting and parsing helpers shared by logging, diagnostics and the
/// packet-diff developer tool.
public enum HexDump {
    /// "1A 2B 3C" style single-line dump.
    public static func compact(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Classic 16-bytes-per-row dump with offsets, for report descriptors.
    public static func multiline(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<Swift.min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            return String(format: "%04X  %@", offset, hex)
        }.joined(separator: "\n")
    }

    /// Parses user-entered hex: accepts spaces, commas, newlines and an
    /// optional `0x` prefix per byte. Returns nil on any malformed token.
    public static func parse(_ text: String) -> [UInt8]? {
        let separators = CharacterSet(charactersIn: " ,\n\t\r")
        var tokens = text
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .map { token -> String in
                token.lowercased().hasPrefix("0x") ? String(token.dropFirst(2)) : token
            }
        // Also accept one contiguous run like "0a1b2c".
        if tokens.count == 1, tokens[0].count > 2, tokens[0].count % 2 == 0 {
            let run = tokens[0]
            tokens = stride(from: 0, to: run.count, by: 2).map {
                let start = run.index(run.startIndex, offsetBy: $0)
                let end = run.index(start, offsetBy: 2)
                return String(run[start..<end])
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(tokens.count)
        for token in tokens {
            guard token.count <= 2, let value = UInt8(token, radix: 16) else { return nil }
            bytes.append(value)
        }
        return bytes.isEmpty ? nil : bytes
    }
}
