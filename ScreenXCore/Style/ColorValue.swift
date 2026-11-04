import CoreGraphics
import Foundation

/// An sRGB color with components in 0...1. Encoded as `"#RRGGBB"` or `"#RRGGBBAA"`.
public struct ColorValue: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` (the leading `#` is optional, case-insensitive).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8,
              s.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = hasAlpha ? (value >> 24) & 0xFF : (value >> 16) & 0xFF
        let g = hasAlpha ? (value >> 16) & 0xFF : (value >> 8) & 0xFF
        let b = hasAlpha ? (value >> 8) & 0xFF : value & 0xFF
        let a = hasAlpha ? value & 0xFF : 255
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: Double(a) / 255)
    }

    /// Uppercase `#RRGGBB`, or `#RRGGBBAA` when alpha is below 1.
    public var hex: String {
        func byte(_ v: Double) -> String {
            let hex = String(Int((min(max(v, 0), 1) * 255).rounded()), radix: 16, uppercase: true)
            return hex.count == 1 ? "0" + hex : hex
        }
        let rgb = "#" + byte(red) + byte(green) + byte(blue)
        return alpha == 1 ? rgb : rgb + byte(alpha)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let color = ColorValue(hex: string) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid hex color: \(string)"))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
