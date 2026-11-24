import Foundation

public struct GradientStop: Codable, Hashable, Sendable {
    public var color: ColorValue
    public var location: Double

    public init(color: ColorValue, location: Double) {
        self.color = color
        self.location = location
    }
}

/// Canvas background. `gradient` angle uses CSS semantics: 0° points up
/// (bottom to top), 90° right, 135° top-left to bottom-right.
public enum Background: Codable, Hashable, Sendable {
    case gradient(stops: [GradientStop], angle: Double)
    case solid(ColorValue)
    case image(file: String)
    case blurredScreenshot(radius: Double)
    case none

    private enum CodingKeys: String, CodingKey {
        case type, stops, angle, color, file, radius
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "gradient":
            self = .gradient(stops: try c.decode([GradientStop].self, forKey: .stops),
                             angle: try c.decode(Double.self, forKey: .angle))
        case "solid":
            self = .solid(try c.decode(ColorValue.self, forKey: .color))
        case "image":
            self = .image(file: try c.decode(String.self, forKey: .file))
        case "blurred":
            self = .blurredScreenshot(radius: try c.decode(Double.self, forKey: .radius))
        case "none":
            self = .none
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown background type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .gradient(stops, angle):
            try c.encode("gradient", forKey: .type)
            try c.encode(stops, forKey: .stops)
            try c.encode(angle, forKey: .angle)
        case let .solid(color):
            try c.encode("solid", forKey: .type)
            try c.encode(color, forKey: .color)
        case let .image(file):
            try c.encode("image", forKey: .type)
            try c.encode(file, forKey: .file)
        case let .blurredScreenshot(radius):
            try c.encode("blurred", forKey: .type)
            try c.encode(radius, forKey: .radius)
        case .none:
            try c.encode("none", forKey: .type)
        }
    }
}
