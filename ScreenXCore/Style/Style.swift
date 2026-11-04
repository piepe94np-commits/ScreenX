import Foundation

public struct ShadowStyle: Codable, Hashable, Sendable {
    public var strength: Double
    public var offsetY: Double?
    public var blur: Double?
    public var opacity: Double?

    public init(strength: Double, offsetY: Double? = nil, blur: Double? = nil, opacity: Double? = nil) {
        self.strength = strength
        self.offsetY = offsetY
        self.blur = blur
        self.opacity = opacity
    }

    /// Unset detail fields are derived from `strength`; set fields override.
    public func resolved() -> (offsetY: Double, blur: Double, opacity: Double) {
        (offsetY: offsetY ?? strength * 0.4,
         blur: blur ?? strength * 0.8,
         opacity: opacity ?? strength / 100 * 0.55)
    }

    private enum CodingKeys: String, CodingKey { case strength, offsetY, blur, opacity }

    // Explicit nulls for unset detail fields, as in the document format.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(strength, forKey: .strength)
        try c.encode(offsetY, forKey: .offsetY)
        try c.encode(blur, forKey: .blur)
        try c.encode(opacity, forKey: .opacity)
    }
}

public enum AspectRatio: Codable, Hashable, Sendable, CaseIterable {
    case auto, r16x9, r4x3, r1x1, r9x16, r3x2

    private var code: String {
        switch self {
        case .auto: "auto"
        case .r16x9: "16:9"
        case .r4x3: "4:3"
        case .r1x1: "1:1"
        case .r9x16: "9:16"
        case .r3x2: "3:2"
        }
    }

    /// Width / height; `nil` for `auto`.
    public var ratio: Double? {
        switch self {
        case .auto: nil
        case .r16x9: 16.0 / 9.0
        case .r4x3: 4.0 / 3.0
        case .r1x1: 1
        case .r9x16: 9.0 / 16.0
        case .r3x2: 3.0 / 2.0
        }
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let match = Self.allCases.first(where: { $0.code == string }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown aspect ratio: \(string)"))
        }
        self = match
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

public enum ContentAlignment: String, Codable, Hashable, Sendable, CaseIterable {
    case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing

    private var code: String {
        switch self {
        case .topLeading: "topLeft"
        case .top: "top"
        case .topTrailing: "topRight"
        case .leading: "left"
        case .center: "center"
        case .trailing: "right"
        case .bottomLeading: "bottomLeft"
        case .bottom: "bottom"
        case .bottomTrailing: "bottomRight"
        }
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let match = Self.allCases.first(where: { $0.code == string }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown alignment: \(string)"))
        }
        self = match
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

public struct Style: Codable, Hashable, Sendable {
    public var background: Background
    public var padding: Double
    public var cornerRadius: Double
    public var shadow: ShadowStyle
    /// Reserved: kept in the model and JSON for compatibility, but not used by the renderer and not shown in M2.
    public var keepWindowShadow: Bool
    public var aspect: AspectRatio
    public var alignment: ContentAlignment
    /// 3D tilt of the content (with or without device template).
    public var tilt: Tilt

    public init(background: Background, padding: Double, cornerRadius: Double, shadow: ShadowStyle,
                keepWindowShadow: Bool, aspect: AspectRatio, alignment: ContentAlignment, tilt: Tilt = .zero) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.keepWindowShadow = keepWindowShadow
        self.aspect = aspect
        self.alignment = alignment
        self.tilt = tilt
    }

    private enum CodingKeys: String, CodingKey {
        case background, padding, cornerRadius, shadow, keepWindowShadow, aspect, alignment, tilt
    }

    /// Tolerant: missing fields (e.g. `tilt` in projects from M2/M3) take the `.default` values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Style.default
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? d.background
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        shadow = try c.decodeIfPresent(ShadowStyle.self, forKey: .shadow) ?? d.shadow
        keepWindowShadow = try c.decodeIfPresent(Bool.self, forKey: .keepWindowShadow) ?? d.keepWindowShadow
        aspect = try c.decodeIfPresent(AspectRatio.self, forKey: .aspect) ?? d.aspect
        alignment = try c.decodeIfPresent(ContentAlignment.self, forKey: .alignment) ?? d.alignment
        tilt = try c.decodeIfPresent(Tilt.self, forKey: .tilt) ?? d.tilt
    }

    public static let `default` = Style(
        background: GradientPresets.all[0],
        padding: 64,
        cornerRadius: 12,
        shadow: ShadowStyle(strength: 50),
        keepWindowShadow: false,
        aspect: .auto,
        alignment: .center)
}

extension Style {
    /// Start style for a new capture: `lastStyle` when `applyLastStyle` is on and one exists,
    /// otherwise `.default`. `keepWindowShadow` always starts at its default, and an image
    /// background falls back to the default background (a new capture has no image data).
    public static func forNewCapture(lastStyle: Style?, applyLastStyle: Bool) -> Style {
        guard applyLastStyle, var style = lastStyle else { return .default }
        style.keepWindowShadow = Style.default.keepWindowShadow
        if case .image = style.background { style.background = Style.default.background }
        return style
    }
}
