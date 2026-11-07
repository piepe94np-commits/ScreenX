import CoreGraphics
import Foundation

/// Pure geometry for picking a template's screen corners on an image shown fitted in a view.
/// View and image coordinates both have their origin top-left with y pointing down; image coordinates
/// are pixels of the frame image (as `DeviceTemplate.screenQuad`).
public enum QuadPicking {
    /// `imageSize` fitted (aspect kept) and centered in `bounds`; empty for an empty image or bounds.
    public static func fittedRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: CGPoint(x: bounds.midX, y: bounds.midY), size: .zero)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// View point → image pixel (not clamped). `fittedRect` is where the image is drawn.
    public static func toImage(_ viewPoint: CGPoint, imageSize: CGSize, fittedRect: CGRect) -> CGPoint {
        guard fittedRect.width > 0, fittedRect.height > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - fittedRect.minX) * imageSize.width / fittedRect.width,
                       y: (viewPoint.y - fittedRect.minY) * imageSize.height / fittedRect.height)
    }

    /// Image pixel → view point.
    public static func toView(_ imagePoint: CGPoint, imageSize: CGSize, fittedRect: CGRect) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return fittedRect.origin }
        return CGPoint(x: fittedRect.minX + imagePoint.x * fittedRect.width / imageSize.width,
                       y: fittedRect.minY + imagePoint.y * fittedRect.height / imageSize.height)
    }

    /// `point` clamped into `[0, width] × [0, height]`; a non-finite coordinate becomes 0.
    public static func clamped(_ point: CGPoint, to imageSize: CGSize) -> CGPoint {
        func clamp(_ v: CGFloat, _ upper: CGFloat) -> CGFloat {
            v.isFinite ? min(max(v, 0), max(upper, 0)) : 0
        }
        return CGPoint(x: clamp(point.x, imageSize.width), y: clamp(point.y, imageSize.height))
    }

    /// Index of the point nearest to `location` within `tolerance` (view points), else `nil`.
    public static func hitIndex(at location: CGPoint, in points: [CGPoint], tolerance: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, p) in points.enumerated() {
            let d = hypot(p.x - location.x, p.y - location.y)
            if d <= tolerance, d < (best?.distance ?? .infinity) { best = (index, d) }
        }
        return best?.index
    }

    /// Four corners in the order a template needs: top-left, top-right, bottom-right, bottom-left
    /// (clockwise on screen, y down).
    /// - If the points, in the order given, already form a simple clockwise polygon (positive signed area
    ///   with y down, no crossing edges), that order is kept; it is only rotated to start at the corner with
    ///   the smallest x + y. This keeps concave or strongly skewed quads as clicked.
    /// - Otherwise they are sorted by angle around their centroid, starting at the corner with the smallest
    ///   x + y (fixes a wrong click order).
    /// Other counts are returned unchanged.
    public static func orderedClockwise(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count == 4 else { return points }
        let cyclic: [CGPoint]
        if isSimpleClockwise(points) {
            cyclic = points
        } else {
            let cx = points.map(\.x).reduce(0, +) / 4, cy = points.map(\.y).reduce(0, +) / 4
            cyclic = points.sorted { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
        }
        guard let start = cyclic.indices.min(by: { cyclic[$0].x + cyclic[$0].y < cyclic[$1].x + cyclic[$1].y })
        else { return points }
        return Array(cyclic[start...] + cyclic[..<start])
    }

    /// Four points that form a simple polygon, clockwise on screen (y down): positive shoelace area and
    /// neither pair of opposite edges crosses.
    static func isSimpleClockwise(_ p: [CGPoint]) -> Bool {
        guard p.count == 4 else { return false }
        var area: CGFloat = 0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            area += a.x * b.y - b.x * a.y
        }
        guard area.isFinite, area > 0 else { return false }
        return !segmentsCross(p[0], p[1], p[2], p[3]) && !segmentsCross(p[1], p[2], p[3], p[0])
    }

    /// Segments a–b and c–d intersect (touching counts).
    private static func segmentsCross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat {
            (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
        }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        return d1 * d2 <= 0 && d3 * d4 <= 0
    }

    /// Relative tolerance of `snappedToRectangle`: edge deviation per frame side.
    public static let straightTolerance: CGFloat = 0.01

    /// An ordered quad (TL, TR, BR, BL) whose edges are axis-parallel within `straightTolerance` of the
    /// respective image side: the top and bottom edges differ in y by at most 1 % of the height, the left and
    /// right edges in x by at most 1 % of the width.
    public static func isNearlyRectangular(_ quad: [CGPoint], imageSize: CGSize) -> Bool {
        guard quad.count == 4, imageSize.width > 0, imageSize.height > 0,
              quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return false }
        let tx = imageSize.width * straightTolerance, ty = imageSize.height * straightTolerance
        let q = quad
        return abs(q[0].y - q[1].y) <= ty && abs(q[3].y - q[2].y) <= ty
            && abs(q[0].x - q[3].x) <= tx && abs(q[1].x - q[2].x) <= tx
            // Still the TL, TR, BR, BL arrangement (not a degenerate or mirrored quad).
            && q[1].x > q[0].x && q[2].x > q[3].x && q[3].y > q[0].y && q[2].y > q[1].y
    }

    /// A hand-clicked quad that is nearly an axis-parallel rectangle (`isNearlyRectangular`) becomes exactly
    /// its axis-aligned bounds (TL, TR, BR, BL, clamped to the image), so the template counts as rectangular
    /// and annotations stay editable. A real skew or perspective is returned unchanged.
    public static func snappedToRectangle(_ quad: [CGPoint], imageSize: CGSize) -> [CGPoint] {
        guard isNearlyRectangular(quad, imageSize: imageSize) else { return quad }
        let xs = quad.map(\.x), ys = quad.map(\.y)
        let tl = clamped(CGPoint(x: xs.min()!, y: ys.min()!), to: imageSize)
        let br = clamped(CGPoint(x: xs.max()!, y: ys.max()!), to: imageSize)
        return [tl, CGPoint(x: br.x, y: tl.y), br, CGPoint(x: tl.x, y: br.y)]
    }
}
