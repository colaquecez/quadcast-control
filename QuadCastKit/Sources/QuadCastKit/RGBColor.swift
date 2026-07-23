import Foundation

/// An 8-bit-per-channel RGB color as sent to the device.
public struct RGBColor: Sendable, Equatable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Creates a color from floating-point components in `0.0...1.0`
    /// (distinct labels avoid literal-type ambiguity with the byte init).
    /// Out-of-range values are clamped, never trapped on.
    public init(unitRed: Double, unitGreen: Double, unitBlue: Double) {
        self.red = Self.byte(from: unitRed)
        self.green = Self.byte(from: unitGreen)
        self.blue = Self.byte(from: unitBlue)
    }

    private static func byte(from unit: Double) -> UInt8 {
        guard !unit.isNaN else { return 0 }
        return UInt8((unit.clamped(to: 0.0...1.0) * 255.0).rounded())
    }

    /// The 3-byte wire encoding in R, G, B order.
    /// NOTE: byte *order* on the wire is protocol-specific; encoders may
    /// reorder these (some HyperX packets have been observed as G/R/B on
    /// other models). This is the canonical in-memory order only.
    public var rgbBytes: [UInt8] { [red, green, blue] }

    /// "RRGGBB" uppercase hex, for display and logging.
    public var hexString: String {
        String(format: "%02X%02X%02X", red, green, blue)
    }

    /// Parses "RRGGBB" or "#RRGGBB". Returns nil for anything else.
    public init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }

    public static let white = RGBColor(red: 255, green: 255, blue: 255)
    public static let black = RGBColor(red: 0, green: 0, blue: 0)
}

/// LED brightness expressed as a percentage the UI works in.
public struct Brightness: Sendable, Equatable, Hashable {
    /// 0...100, always clamped on construction.
    public let percent: Int

    public init(percent: Int) {
        self.percent = percent.clamped(to: 0...100)
    }

    /// Device-side byte in `0...255`, linearly scaled and rounded.
    public var deviceByte: UInt8 {
        UInt8((Double(percent) / 100.0 * 255.0).rounded())
    }

    /// Inverse conversion for values read back from the device.
    public init(deviceByte: UInt8) {
        self.percent = Int((Double(deviceByte) / 255.0 * 100.0).rounded())
    }

    public static let full = Brightness(percent: 100)
    public static let off = Brightness(percent: 0)
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
