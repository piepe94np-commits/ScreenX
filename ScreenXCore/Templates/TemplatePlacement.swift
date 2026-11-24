import CoreGraphics
import Foundation

/// 3D tilt in degrees around the X and Y axis. JSON: `{"x":0,"y":0}`.
public struct Tilt: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Tilt(x: 0, y: 0)

    private enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
    }
}

/// How the screen content is placed into the template's screen.
public enum FitMode: String, Codable, Sendable {
    /// Crop to the screen's aspect; the crop can be moved with `offset`.
    case fill
    /// Show the whole content, letterboxed with `fillColor`.
    case fit
}

/// The template used by a document (`document.json` → `template`).
public struct TemplatePlacement: Codable, Hashable, Sendable {
    public var templateID: String
    public var fit: FitMode
    /// Letterbox color for `.fit`.
    public var fillColor: ColorValue
    /// Crop offset for `.fill`, each axis -1…1 (0 = centered).
    public var offset: CGPoint
    /// Text of the URL field; only used by browser templates.
    public var urlText: String?

    public init(templateID: String, fit: FitMode = .fill, fillColor: ColorValue = ColorValue(red: 0, green: 0, blue: 0),
                offset: CGPoint = .zero, urlText: String? = nil) {
        self.templateID = templateID
        self.fit = fit
        self.fillColor = fillColor
        self.offset = offset
        self.urlText = urlText
    }

    private enum CodingKeys: String, CodingKey { case templateID, fit, fillColor, offset, urlText }
    private enum OffsetKeys: String, CodingKey { case x, y }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templateID = try c.decode(String.self, forKey: .templateID)
        fit = try c.decodeIfPresent(FitMode.self, forKey: .fit) ?? .fill
        fillColor = try c.decodeIfPresent(ColorValue.self, forKey: .fillColor) ?? ColorValue(red: 0, green: 0, blue: 0)
        if c.contains(.offset), try !c.decodeNil(forKey: .offset) {
            let k = try c.nestedContainer(keyedBy: OffsetKeys.self, forKey: .offset)
            offset = CGPoint(x: try k.decodeIfPresent(Double.self, forKey: .x) ?? 0,
                             y: try k.decodeIfPresent(Double.self, forKey: .y) ?? 0)
        } else {
            offset = .zero
        }
        urlText = try c.decodeIfPresent(String.self, forKey: .urlText)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(templateID, forKey: .templateID)
        try c.encode(fit, forKey: .fit)
        try c.encode(fillColor, forKey: .fillColor)
        var k = c.nestedContainer(keyedBy: OffsetKeys.self, forKey: .offset)
        try k.encode(Double(offset.x), forKey: .x)
        try k.encode(Double(offset.y), forKey: .y)
        try c.encode(urlText, forKey: .urlText)
    }
}
