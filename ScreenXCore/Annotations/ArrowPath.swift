import CoreGraphics
import Foundation

/// Geometry of an arrow annotation in original pixels (origin top-left).
///
/// The shaft is a line or a quadratic Bézier curve. Filled heads are triangles and the shaft stops at
/// their base; open heads are two strokes meeting at the tip and the shaft runs up to the tip.
struct ArrowPath {
    /// Angle between each side of the head and the shaft.
    static let headAngle: CGFloat = 28 * .pi / 180

    static func headLength(strokeWidth: Double) -> CGFloat { max(18, 4 * CGFloat(strokeWidth)) }

    /// `nil` when the arrow has no length.
    let shaft: CGPath?
    /// Closed triangles when `headsFilled`, otherwise open polylines (side, tip, side).
    let heads: [CGPath]
    let headsFilled: Bool

    init(start: CGPoint, end: CGPoint, control: CGPoint?, head: ArrowHead, strokeWidth: Double) {
        let length = Self.headLength(strokeWidth: strokeWidth)
        headsFilled = head != .open
        let baseDistance = headsFilled ? length * cos(Self.headAngle) : 0

        // Head direction = tangent at the end (for a quadratic curve: end − control).
        guard let endDirection = Self.unit(end, from: control ?? start) ?? Self.unit(end, from: start) else {
            shaft = nil
            heads = []
            return
        }
        var shaftStart = start
        let shaftEnd = Self.offset(end, endDirection, -baseDistance)
        var heads = [Self.headPath(tip: end, direction: endDirection, length: length, closed: headsFilled)]
        if head == .double,
           let startDirection = Self.unit(start, from: control ?? end) ?? Self.unit(start, from: end) {
            shaftStart = Self.offset(start, startDirection, -baseDistance)
            heads.append(Self.headPath(tip: start, direction: startDirection, length: length, closed: true))
        }
        self.heads = heads

        let path = CGMutablePath()
        if let control {
            path.move(to: shaftStart)
            path.addQuadCurve(to: shaftEnd, control: control)
            shaft = path
        } else {
            // A straight arrow shorter than its head(s): no shaft, the heads alone.
            let dx = shaftEnd.x - shaftStart.x, dy = shaftEnd.y - shaftStart.y
            if dx * (end.x - start.x) + dy * (end.y - start.y) <= 0 {
                shaft = nil
            } else {
                path.move(to: shaftStart)
                path.addLine(to: shaftEnd)
                shaft = path
            }
        }
    }

    private static func unit(_ p: CGPoint, from q: CGPoint) -> CGVector? {
        let dx = p.x - q.x, dy = p.y - q.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        return CGVector(dx: dx / length, dy: dy / length)
    }

    private static func offset(_ p: CGPoint, _ v: CGVector, _ distance: CGFloat) -> CGPoint {
        CGPoint(x: p.x + v.dx * distance, y: p.y + v.dy * distance)
    }

    private static func rotated(_ v: CGVector, by angle: CGFloat) -> CGVector {
        CGVector(dx: v.dx * cos(angle) - v.dy * sin(angle), dy: v.dx * sin(angle) + v.dy * cos(angle))
    }

    private static func headPath(tip: CGPoint, direction: CGVector, length: CGFloat, closed: Bool) -> CGPath {
        let path = CGMutablePath()
        path.move(to: offset(tip, rotated(direction, by: headAngle), -length))
        path.addLine(to: tip)
        path.addLine(to: offset(tip, rotated(direction, by: -headAngle), -length))
        if closed { path.closeSubpath() }
        return path
    }
}
