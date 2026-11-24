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
        let baseDistance = head != .open ? length * cos(Self.headAngle) : 0
        if let control {
            self.init(curveFrom: start, control: control, to: end, head: head, length: length,
                      baseDistance: baseDistance)
        } else {
            self.init(lineFrom: start, to: end, head: head, length: length, baseDistance: baseDistance)
        }
    }

    private init(lineFrom start: CGPoint, to end: CGPoint, head: ArrowHead, length: CGFloat,
                 baseDistance: CGFloat) {
        headsFilled = head != .open
        guard let endDirection = Self.unit(end, from: start) else {
            shaft = nil
            heads = []
            return
        }
        var shaftStart = start
        let shaftEnd = Self.offset(end, endDirection, -baseDistance)
        var heads = [Self.headPath(tip: end, direction: endDirection, length: length, closed: headsFilled)]
        if head == .double {
            let startDirection = CGVector(dx: -endDirection.dx, dy: -endDirection.dy)
            shaftStart = Self.offset(start, startDirection, -baseDistance)
            heads.append(Self.headPath(tip: start, direction: startDirection, length: length, closed: true))
        }
        self.heads = heads

        // A straight arrow shorter than its head(s): no shaft, the heads alone.
        let dx = shaftEnd.x - shaftStart.x, dy = shaftEnd.y - shaftStart.y
        if dx * (end.x - start.x) + dy * (end.y - start.y) <= 0 {
            shaft = nil
        } else {
            let path = CGMutablePath()
            path.move(to: shaftStart)
            path.addLine(to: shaftEnd)
            shaft = path
        }
    }

    /// Quadratic Bézier start→control→end. The shaft is the exact sub-curve between the parameters whose
    /// points lie `baseDistance` from the tips; each head points along the tangent there.
    private init(curveFrom p0: CGPoint, control p1: CGPoint, to p2: CGPoint, head: ArrowHead, length: CGFloat,
                 baseDistance: CGFloat) {
        headsFilled = head != .open
        func point(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
                           y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y)
        }
        func derivative(_ t: CGFloat) -> CGVector {
            CGVector(dx: 2 * ((1 - t) * (p1.x - p0.x) + t * (p2.x - p1.x)),
                     dy: 2 * ((1 - t) * (p1.y - p0.y) + t * (p2.y - p1.y)))
        }
        func direction(_ v: CGVector, fallback: CGVector?) -> CGVector? {
            let length = hypot(v.dx, v.dy)
            return length > 1e-9 ? CGVector(dx: v.dx / length, dy: v.dy / length) : fallback
        }
        guard let chord = Self.unit(p2, from: p0) else {
            shaft = nil
            heads = []
            return
        }

        let t1 = Self.parameter(distance: baseDistance, from: p2, fromEnd: true, point: point)
        let t0 = head == .double ? Self.parameter(distance: baseDistance, from: p0, fromEnd: false, point: point) : 0
        let endDirection = direction(derivative(t1 ?? 1), fallback: chord) ?? chord
        var heads = [Self.headPath(tip: p2, direction: endDirection, length: length, closed: headsFilled)]
        if head == .double {
            let back = derivative(t0 ?? 0)
            let startDirection = direction(CGVector(dx: -back.dx, dy: -back.dy),
                                           fallback: CGVector(dx: -chord.dx, dy: -chord.dy))!
            heads.append(Self.headPath(tip: p0, direction: startDirection, length: length, closed: true))
        }
        self.heads = heads

        // Clamp: no shaft when the head bases meet or cross (the shaft would invert).
        guard let t0, let t1, t0 < t1 else {
            shaft = nil
            return
        }
        // Sub-curve [t0, t1] of a quadratic: control = B(t0) + (t1 − t0)/2 · B′(t0) (de Casteljau).
        let a = point(t0), b = point(t1), d = derivative(t0)
        let path = CGMutablePath()
        path.move(to: a)
        path.addQuadCurve(to: b, control: CGPoint(x: a.x + (t1 - t0) / 2 * d.dx, y: a.y + (t1 - t0) / 2 * d.dy))
        shaft = path
    }

    /// The parameter nearest the given end whose curve point is `distance` from `tip`, found by sampling
    /// from that end and bisecting; `nil` if the whole curve stays closer than `distance`.
    private static func parameter(distance: CGFloat, from tip: CGPoint, fromEnd: Bool,
                                  point: (CGFloat) -> CGPoint) -> CGFloat? {
        guard distance > 0 else { return fromEnd ? 1 : 0 }
        func far(_ t: CGFloat) -> Bool {
            let p = point(t)
            return hypot(p.x - tip.x, p.y - tip.y) >= distance
        }
        let samples = 128
        var near: CGFloat = fromEnd ? 1 : 0
        for i in 1...samples {
            let t = fromEnd ? 1 - CGFloat(i) / CGFloat(samples) : CGFloat(i) / CGFloat(samples)
            if far(t) {
                var inside = near, outside = t
                for _ in 0..<30 {
                    let mid = (inside + outside) / 2
                    if far(mid) { outside = mid } else { inside = mid }
                }
                return outside
            }
            near = t
        }
        return nil
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
