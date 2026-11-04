import CoreGraphics
import Foundation

public enum ArrowHead: String, Codable, Sendable, CaseIterable { case filled, open, double }
public enum ShapeKind: String, Codable, Sendable, CaseIterable { case rectangle, roundedRectangle, ellipse, line }
public enum BlurMode: String, Codable, Sendable, CaseIterable { case blur, pixelate }

/// The geometry and type-specific attributes of an annotation, in original pixels (origin top-left).
public enum AnnotationKind: Codable, Hashable, Sendable {
    case arrow(start: CGPoint, end: CGPoint, control: CGPoint?, head: ArrowHead)
    /// For `.line`, start and end are opposite corners of `rect` (also with negative width or height);
    /// `rect` is not standardized.
    case shape(kind: ShapeKind, rect: CGRect, filled: Bool)
    case text(frame: CGRect, string: String, fontSize: Double, bold: Bool, background: ColorValue?)
    case note(frame: CGRect, string: String, noteColor: ColorValue)
    case counter(center: CGPoint, number: Int, radius: Double)
    case blur(rect: CGRect, mode: BlurMode, strength: Double)
    case highlight(rect: CGRect)

    private enum CodingKeys: String, CodingKey {
        case type, start, end, control, head, kind, rect, filled, frame, string, fontSize, bold
        case background, noteColor, center, number, radius, mode, strength
    }

    private enum PointKeys: String, CodingKey { case x, y }
    private enum RectKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func point(_ key: CodingKeys) throws -> CGPoint {
            let k = try c.nestedContainer(keyedBy: PointKeys.self, forKey: key)
            return CGPoint(x: try k.decode(Double.self, forKey: .x), y: try k.decode(Double.self, forKey: .y))
        }
        func rect(_ key: CodingKeys) throws -> CGRect {
            let k = try c.nestedContainer(keyedBy: RectKeys.self, forKey: key)
            return CGRect(x: try k.decode(Double.self, forKey: .x), y: try k.decode(Double.self, forKey: .y),
                          width: try k.decode(Double.self, forKey: .width),
                          height: try k.decode(Double.self, forKey: .height))
        }
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "arrow":
            let control: CGPoint? = (c.contains(.control) && !(try c.decodeNil(forKey: .control)))
                ? try point(.control) : nil
            self = .arrow(start: try point(.start), end: try point(.end), control: control,
                          head: try c.decode(ArrowHead.self, forKey: .head))
        case "shape":
            self = .shape(kind: try c.decode(ShapeKind.self, forKey: .kind), rect: try rect(.rect),
                          filled: try c.decode(Bool.self, forKey: .filled))
        case "text":
            self = .text(frame: try rect(.frame), string: try c.decode(String.self, forKey: .string),
                         fontSize: try c.decode(Double.self, forKey: .fontSize),
                         bold: try c.decode(Bool.self, forKey: .bold),
                         background: try c.decodeIfPresent(ColorValue.self, forKey: .background))
        case "note":
            self = .note(frame: try rect(.frame), string: try c.decode(String.self, forKey: .string),
                         noteColor: try c.decode(ColorValue.self, forKey: .noteColor))
        case "counter":
            self = .counter(center: try point(.center), number: try c.decode(Int.self, forKey: .number),
                            radius: try c.decode(Double.self, forKey: .radius))
        case "blur":
            self = .blur(rect: try rect(.rect), mode: try c.decode(BlurMode.self, forKey: .mode),
                         strength: try c.decode(Double.self, forKey: .strength))
        case "highlight":
            self = .highlight(rect: try rect(.rect))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "Unknown annotation type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func put(_ p: CGPoint, _ key: CodingKeys) throws {
            var k = c.nestedContainer(keyedBy: PointKeys.self, forKey: key)
            try k.encode(Double(p.x), forKey: .x)
            try k.encode(Double(p.y), forKey: .y)
        }
        func put(_ r: CGRect, _ key: CodingKeys) throws {
            var k = c.nestedContainer(keyedBy: RectKeys.self, forKey: key)
            try k.encode(Double(r.origin.x), forKey: .x)
            try k.encode(Double(r.origin.y), forKey: .y)
            try k.encode(Double(r.size.width), forKey: .width)
            try k.encode(Double(r.size.height), forKey: .height)
        }
        switch self {
        case let .arrow(start, end, control, head):
            try c.encode("arrow", forKey: .type)
            try put(start, .start)
            try put(end, .end)
            if let control { try put(control, .control) } else { try c.encodeNil(forKey: .control) }
            try c.encode(head, forKey: .head)
        case let .shape(kind, rect, filled):
            try c.encode("shape", forKey: .type)
            try c.encode(kind, forKey: .kind)
            try put(rect, .rect)
            try c.encode(filled, forKey: .filled)
        case let .text(frame, string, fontSize, bold, background):
            try c.encode("text", forKey: .type)
            try put(frame, .frame)
            try c.encode(string, forKey: .string)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encode(bold, forKey: .bold)
            try c.encodeIfPresent(background, forKey: .background)
        case let .note(frame, string, noteColor):
            try c.encode("note", forKey: .type)
            try put(frame, .frame)
            try c.encode(string, forKey: .string)
            try c.encode(noteColor, forKey: .noteColor)
        case let .counter(center, number, radius):
            try c.encode("counter", forKey: .type)
            try put(center, .center)
            try c.encode(number, forKey: .number)
            try c.encode(radius, forKey: .radius)
        case let .blur(rect, mode, strength):
            try c.encode("blur", forKey: .type)
            try put(rect, .rect)
            try c.encode(mode, forKey: .mode)
            try c.encode(strength, forKey: .strength)
        case let .highlight(rect):
            try c.encode("highlight", forKey: .type)
            try put(rect, .rect)
        }
    }
}

public struct Annotation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: AnnotationKind
    public var color: ColorValue
    public var strokeWidth: Double
    /// Radians, around the center of the (unrotated) bounds.
    public var rotation: Double

    public init(id: UUID = UUID(), kind: AnnotationKind,
                color: ColorValue = AnnotationPalette.defaultColor,
                strokeWidth: Double = AnnotationPalette.defaultStrokeWidth,
                rotation: Double = 0) {
        self.id = id
        self.kind = kind
        self.color = color
        self.strokeWidth = strokeWidth
        self.rotation = rotation
    }

    private enum CodingKeys: String, CodingKey { case id, color, strokeWidth, rotation }

    /// The kind's fields are stored flat next to `id`, `color`, `strokeWidth` and `rotation`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        color = try c.decode(ColorValue.self, forKey: .color)
        strokeWidth = try c.decode(Double.self, forKey: .strokeWidth)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        kind = try AnnotationKind(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(color, forKey: .color)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encode(rotation, forKey: .rotation)
        try kind.encode(to: encoder)
    }
}
