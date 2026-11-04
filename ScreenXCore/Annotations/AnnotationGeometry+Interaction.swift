import CoreGraphics
import Foundation

/// Geometry for editing annotations on the canvas: rotation between the annotation's unrotated frame and
/// the original, rubber-band selection and resizing that respects rotation. Points are in original pixels.
extension AnnotationGeometry {
    /// Center of the unrotated bounds; annotations rotate around it.
    public static func pivot(of a: Annotation) -> CGPoint {
        let box = bounds(a)
        return CGPoint(x: box.midX, y: box.midY)
    }

    /// From the annotation's unrotated frame into the original (applies `rotation`).
    public static func toOriginal(_ p: CGPoint, of a: Annotation) -> CGPoint {
        rotatePoint(p, around: pivot(of: a), by: a.rotation)
    }

    /// From the original into the annotation's unrotated frame.
    public static func toLocal(_ p: CGPoint, of a: Annotation) -> CGPoint {
        rotatePoint(p, around: pivot(of: a), by: -a.rotation)
    }

    /// Corners of the rotated bounds in the original: top-left, top-right, bottom-right, bottom-left.
    public static func outline(of a: Annotation) -> [CGPoint] {
        let r = bounds(a)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { toOriginal($0, of: a) }
    }

    /// Annotations whose rotated bounds (widened by half the stroke, so straight lines count) touch `rect`,
    /// in array order.
    public static func ids(intersecting rect: CGRect, in annotations: [Annotation]) -> [UUID] {
        let area = rect.standardized
        return annotations.filter { a in
            let corners = outline(of: a)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let reach = max(CGFloat(a.strokeWidth) / 2, 0.5)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                .insetBy(dx: -reach, dy: -reach)
            return box.intersects(area)
        }.map(\.id)
    }

    /// Drags `handle` to `p` (in the original, i.e. already rotated). The point opposite to the handle stays
    /// where it is on screen, also for rotated annotations: resizing moves the pivot, so the result is shifted
    /// back by the displacement the moved pivot would cause.
    /// `constrained`: endpoints of arrows and lines snap to 45° around the other end; box handles keep
    /// the aspect ratio.
    public static func resized(_ a: Annotation, handle: Handle, toOriginal p: CGPoint, constrained: Bool) -> Annotation {
        var local = toLocal(p, of: a)
        let anchor = endpointAnchor(of: a, handle: handle)
        if constrained, let anchor { local = snapAngle(from: anchor, to: local) }
        let result = resized(a, handle: handle, to: local, proportional: constrained && anchor == nil)
        guard a.rotation != 0 else { return result }

        let old = pivot(of: a), new = pivot(of: result)
        let d = CGVector(dx: new.x - old.x, dy: new.y - old.y)
        let cosA = CGFloat(cos(a.rotation)), sinA = CGFloat(sin(a.rotation))
        let rotated = CGVector(dx: d.dx * cosA - d.dy * sinA, dy: d.dx * sinA + d.dy * cosA)
        return moved(result, by: CGVector(dx: rotated.dx - d.dx, dy: rotated.dy - d.dy))
    }

    /// The fixed other end when dragging the start or end of an arrow or line; `nil` for other handles.
    private static func endpointAnchor(of a: Annotation, handle: Handle) -> CGPoint? {
        switch (a.kind, handle) {
        case let (.arrow(_, end, _, _), .start): end
        case let (.arrow(start, _, _, _), .end): start
        case let (.shape(.line, rect, _), .start): CGPoint(x: rect.origin.x + rect.size.width,
                                                           y: rect.origin.y + rect.size.height)
        case let (.shape(.line, rect, _), .end): rect.origin
        default: nil
        }
    }

    private static func rotatePoint(_ p: CGPoint, around c: CGPoint, by angle: Double) -> CGPoint {
        guard angle != 0 else { return p }
        let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cosA - dy * sinA, y: c.y + dx * sinA + dy * cosA)
    }
}
