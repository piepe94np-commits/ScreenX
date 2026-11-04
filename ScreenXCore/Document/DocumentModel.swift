import CoreGraphics
import Foundation

public struct OriginalInfo: Codable, Hashable, Sendable {
    public var file: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var mode: CaptureMode?
    public var windowTitle: String?

    public init(file: String = "original.png", pixelWidth: Int, pixelHeight: Int, scale: Double,
                mode: CaptureMode? = nil, windowTitle: String? = nil) {
        self.file = file
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.mode = mode
        self.windowTitle = windowTitle
    }
}

/// Contents of `document.json`.
public struct DocumentModel: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var original: OriginalInfo
    /// Crop in original pixels, origin top-left. `nil` uses the whole original.
    public var crop: CGRect?
    public var style: Style

    public init(version: Int = DocumentModel.currentVersion, original: OriginalInfo,
                crop: CGRect? = nil, style: Style) {
        self.version = version
        self.original = original
        self.crop = crop
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case version, original, crop, style, template, annotations
    }

    private enum CropKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        original = try c.decode(OriginalInfo.self, forKey: .original)
        style = try c.decode(Style.self, forKey: .style)
        if try c.decodeNil(forKey: .crop) || !c.contains(.crop) {
            crop = nil
        } else {
            let k = try c.nestedContainer(keyedBy: CropKeys.self, forKey: .crop)
            crop = CGRect(x: try k.decode(Double.self, forKey: .x),
                          y: try k.decode(Double.self, forKey: .y),
                          width: try k.decode(Double.self, forKey: .width),
                          height: try k.decode(Double.self, forKey: .height))
        }
        // `template` and `annotations` are ignored until later milestones use them.
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(original, forKey: .original)
        if let crop {
            var k = c.nestedContainer(keyedBy: CropKeys.self, forKey: .crop)
            try k.encode(Double(crop.origin.x), forKey: .x)
            try k.encode(Double(crop.origin.y), forKey: .y)
            try k.encode(Double(crop.size.width), forKey: .width)
            try k.encode(Double(crop.size.height), forKey: .height)
        } else {
            try c.encodeNil(forKey: .crop)
        }
        try c.encode(style, forKey: .style)
        try c.encodeNil(forKey: .template)
        try c.encode([String](), forKey: .annotations)
    }
}
