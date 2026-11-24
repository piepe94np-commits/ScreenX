import CoreGraphics
import Foundation

/// Source of a template's frame artwork. JSON: `{"builtin":"<id>"}` or `{"file":"<name>.png"}`.
public enum TemplateFrame: Codable, Hashable, Sendable {
    /// Vector artwork drawn in code (`DeviceArtwork`).
    case builtin(String)
    /// Image file of a custom template.
    case file(String)

    private enum CodingKeys: String, CodingKey { case builtin, file }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .builtin) {
            self = .builtin(id)
        } else if let file = try c.decodeIfPresent(String.self, forKey: .file) {
            self = .file(file)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Template frame needs \"builtin\" or \"file\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let id): try c.encode(id, forKey: .builtin)
        case .file(let file): try c.encode(file, forKey: .file)
        }
    }
}

/// A device frame with the screen area the screenshot is placed into (spec §7).
public struct DeviceTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var frame: TemplateFrame
    /// Size of the frame artwork in its own units.
    public var frameSize: CGSize
    /// Screen corners in frame coordinates (origin top-left): top-left, top-right, bottom-right, bottom-left.
    public var screenQuad: [CGPoint]
    public var screenCornerRadius: Double
    /// Recommended content aspect as `[width, height]`; `nil` when any aspect fits (e.g. browser).
    public var preferredAspect: [Int]?

    public init(id: String, name: String, frame: TemplateFrame, frameSize: CGSize, screenQuad: [CGPoint],
                screenCornerRadius: Double, preferredAspect: [Int]?) {
        precondition(screenQuad.count == 4, "screenQuad needs exactly 4 points")
        self.id = id
        self.name = name
        self.frame = frame
        self.frameSize = frameSize
        self.screenQuad = screenQuad
        self.screenCornerRadius = screenCornerRadius
        self.preferredAspect = preferredAspect
    }

    /// Bounding box of `screenQuad`.
    public var screenBounds: CGRect {
        let xs = screenQuad.map(\.x), ys = screenQuad.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The quad is an axis-parallel rectangle (tolerance 0.5 units).
    public var isRectangular: Bool {
        guard screenQuad.count == 4 else { return false }
        let q = screenQuad, tolerance = 0.5
        func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
        return same(q[0].y, q[1].y) && same(q[2].y, q[3].y) && same(q[0].x, q[3].x) && same(q[1].x, q[2].x)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, frame, frameSize, screenQuad, screenCornerRadius, preferredAspect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        frame = try c.decode(TemplateFrame.self, forKey: .frame)
        let pairs = try c.decode([[Double]].self, forKey: .screenQuad)
        guard pairs.count == 4, pairs.allSatisfy({ $0.count == 2 }) else {
            throw DecodingError.dataCorruptedError(forKey: .screenQuad, in: c,
                                                   debugDescription: "screenQuad needs 4 [x, y] pairs")
        }
        screenQuad = pairs.map { CGPoint(x: $0[0], y: $0[1]) }
        screenCornerRadius = try c.decodeIfPresent(Double.self, forKey: .screenCornerRadius) ?? 0
        preferredAspect = try c.decodeIfPresent([Int].self, forKey: .preferredAspect)
        // `frameSize` is not in the spec §7 example; without it the frame is assumed to end at the quad.
        if let size = try c.decodeIfPresent([Double].self, forKey: .frameSize), size.count == 2 {
            frameSize = CGSize(width: size[0], height: size[1])
        } else {
            frameSize = CGSize(width: screenQuad.map(\.x).max() ?? 0, height: screenQuad.map(\.y).max() ?? 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(frame, forKey: .frame)
        try c.encode([Double(frameSize.width), Double(frameSize.height)], forKey: .frameSize)
        try c.encode(screenQuad.map { [Double($0.x), Double($0.y)] }, forKey: .screenQuad)
        try c.encode(screenCornerRadius, forKey: .screenCornerRadius)
        try c.encode(preferredAspect, forKey: .preferredAspect)
    }
}
