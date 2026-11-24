import CoreGraphics
import Foundation

public enum Handle: Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end, control, rotate
}

/// Pure geometry for annotations. All points are in original pixels (origin top-left).
public enum AnnotationGeometry {
    /// Distance of the rotation handle above the top-center of the bounds.
    public static let rotateHandleOffset: CGFloat = 30

    /// The size of the annotation's frame (text and note), otherwise of its bounds.
    public static func frameSize(of a: Annotation) -> CGSize {
        bounds(a, textMeasure: { _ in .zero }).size
    }

    /// Axis-aligned bounds in the original, **without** rotation.
    public static func bounds(_ a: Annotation, textMeasure: (Annotation) -> CGSize = frameSize(of:)) -> CGRect {
        switch a.kind {
        case let .arrow(start, end, control, _):
            let points = [start, end] + (control.map { [$0] } ?? [])
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        case let .shape(_, rect, _), let .blur(rect, _, _), let .highlight(rect):
            return rect.standardized
        case let .text(frame, _, _, _, _), let .note(frame, _, _):
            return frame.standardized
        case let .counter(center, _, radius):
            let r = CGFloat(radius)
            return CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        }
    }

    // MARK: Hit testing

    /// Topmost annotation (last in the array) at `p`. `tolerance` is already in original pixels.
    public static func hitTest(_ p: CGPoint, in annotations: [Annotation], tolerance: CGFloat) -> UUID? {
        annotations.last { hits($0, p, tolerance: tolerance) }?.id
    }

    private static func hits(_ a: Annotation, _ point: CGPoint, tolerance: CGFloat) -> Bool {
        let box = bounds(a)
        let center = CGPoint(x: box.midX, y: box.midY)
        let p = rotate(point, around: center, by: -a.rotation)
        let reach = tolerance + CGFloat(a.strokeWidth) / 2

        switch a.kind {
        case let .arrow(start, end, control, _):
            guard let control else { return distanceToSegment(p, start, end) <= reach }
            let samples = (0...32).map { i -> CGPoint in
                let t = CGFloat(i) / 32, u = 1 - t
                return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                               y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
            }
            return zip(samples, samples.dropFirst()).contains { distanceToSegment(p, $0, $1) <= reach }
        case let .shape(kind, rect, filled):
            let r = rect.standardized
            switch kind {
            case .line:
                return distanceToSegment(p, rect.origin, lineEnd(rect)) <= reach
            case .rectangle, .roundedRectangle:
                return filled ? r.contains(p) : distanceToRectBorder(p, r) <= reach
            case .ellipse:
                return filled ? insideEllipse(p, r) : distanceToEllipseBorder(p, r) <= reach
            }
        case .text, .note, .blur, .highlight:
            return box.contains(p)
        case let .counter(c, _, radius):
            return hypot(p.x - c.x, p.y - c.y) <= CGFloat(radius)
        }
    }

    private static func rotate(_ p: CGPoint, around c: CGPoint, by angle: Double) -> CGPoint {
        guard angle != 0 else { return p }
        let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cosA - dy * sinA, y: c.y + dx * sinA + dy * cosA)
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    private static func distanceToRectBorder(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        if r.contains(p) {
            return min(p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y)
        }
        return hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    private static func insideEllipse(_ p: CGPoint, _ r: CGRect) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
        return nx * nx + ny * ny <= 1
    }

    /// First-order distance estimate to the ellipse outline: |F| / |∇F|.
    private static func distanceToEllipseBorder(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let a = r.width / 2, b = r.height / 2
        guard a > 0, b > 0 else { return distanceToRectBorder(p, r) }
        let x = p.x - r.midX, y = p.y - r.midY
        let f = x * x / (a * a) + y * y / (b * b) - 1
        let gradient = hypot(2 * x / (a * a), 2 * y / (b * b))
        guard gradient > 0 else { return min(a, b) }
        return abs(f) / gradient
    }

    // MARK: Handles

    /// Handle positions in the **unrotated** frame; callers rotate them around the bounds center for display
    /// (and rotate pointer positions back before calling `resized`).
    public static func handles(for a: Annotation) -> [Handle: CGPoint] {
        switch a.kind {
        case let .arrow(start, end, control, _):
            var result: [Handle: CGPoint] = [.start: start, .end: end]
            if let control { result[.control] = control }
            return result
        case let .shape(.line, rect, _):
            return [.start: rect.origin, .end: lineEnd(rect)]
        case .counter:
            return [:]
        default:
            let r = bounds(a)
            return [
                .topLeft: CGPoint(x: r.minX, y: r.minY), .top: CGPoint(x: r.midX, y: r.minY),
                .topRight: CGPoint(x: r.maxX, y: r.minY), .right: CGPoint(x: r.maxX, y: r.midY),
                .bottomRight: CGPoint(x: r.maxX, y: r.maxY), .bottom: CGPoint(x: r.midX, y: r.maxY),
                .bottomLeft: CGPoint(x: r.minX, y: r.maxY), .left: CGPoint(x: r.minX, y: r.midY),
                .rotate: CGPoint(x: r.midX, y: r.minY - rotateHandleOffset),
            ]
        }
    }

    // MARK: Editing

    public static func moved(_ a: Annotation, by d: CGVector) -> Annotation {
        func shift(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
        func shift(_ r: CGRect) -> CGRect { r.offsetBy(dx: d.dx, dy: d.dy) }
        var result = a
        switch a.kind {
        case let .arrow(start, end, control, head):
            result.kind = .arrow(start: shift(start), end: shift(end), control: control.map(shift), head: head)
        case let .shape(kind, rect, filled):
            result.kind = .shape(kind: kind, rect: shift(rect), filled: filled)
        case let .text(frame, string, fontSize, bold, background):
            result.kind = .text(frame: shift(frame), string: string, fontSize: fontSize, bold: bold,
                                background: background)
        case let .note(frame, string, noteColor):
            result.kind = .note(frame: shift(frame), string: string, noteColor: noteColor)
        case let .counter(center, number, radius):
            result.kind = .counter(center: shift(center), number: number, radius: radius)
        case let .blur(rect, mode, strength):
            result.kind = .blur(rect: shift(rect), mode: mode, strength: strength)
        case let .highlight(rect):
            result.kind = .highlight(rect: shift(rect))
        }
        return result
    }

    /// `p` is in the unrotated frame. The handle opposite to `handle` stays fixed.
    /// `proportional` keeps the aspect ratio of the current bounds.
    public static func resized(_ a: Annotation, handle: Handle, to p: CGPoint, proportional: Bool) -> Annotation {
        var result = a
        switch (a.kind, handle) {
        case let (.arrow(_, end, control, head), .start):
            result.kind = .arrow(start: p, end: end, control: control, head: head)
        case let (.arrow(start, _, control, head), .end):
            result.kind = .arrow(start: start, end: p, control: control, head: head)
        case let (.arrow(start, end, control, head), .control):
            result.kind = .arrow(start: start, end: end, control: control == nil ? nil : p, head: head)
        case let (.shape(.line, rect, filled), .start):
            result.kind = .shape(kind: .line, rect: rectFromCorners(p, lineEnd(rect)),
                                 filled: filled)
        case let (.shape(.line, rect, filled), .end):
            result.kind = .shape(kind: .line, rect: rectFromCorners(rect.origin, p), filled: filled)
        default:
            guard let newRect = resizedRect(bounds(a), handle: handle, to: p, proportional: proportional) else {
                return a
            }
            result.kind = withRect(a.kind, newRect)
        }
        return result
    }

    /// Opposite corner of a line's `rect` (`maxX`/`maxY` would standardize negative sizes).
    private static func lineEnd(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.origin.x + rect.size.width, y: rect.origin.y + rect.size.height)
    }

    /// Unlike `CGRect.standardized`, keeps the sign of width and height (needed for lines).
    private static func rectFromCorners(_ s: CGPoint, _ e: CGPoint) -> CGRect {
        CGRect(x: s.x, y: s.y, width: e.x - s.x, height: e.y - s.y)
    }

    private static func resizedRect(_ r: CGRect, handle: Handle, to p: CGPoint, proportional: Bool) -> CGRect? {
        let movesLeft = [.topLeft, .left, .bottomLeft].contains(handle)
        let movesRight = [.topRight, .right, .bottomRight].contains(handle)
        let movesTop = [.topLeft, .top, .topRight].contains(handle)
        let movesBottom = [.bottomLeft, .bottom, .bottomRight].contains(handle)
        guard movesLeft || movesRight || movesTop || movesBottom else { return nil }

        // Fixed edges (the opposite side of the dragged handle).
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if movesLeft { minX = p.x }
        if movesRight { maxX = p.x }
        if movesTop { minY = p.y }
        if movesBottom { maxY = p.y }

        if proportional, r.width > 0, r.height > 0 {
            let anchorX = movesLeft ? r.maxX : r.minX
            let anchorY = movesTop ? r.maxY : r.minY
            let hasX = movesLeft || movesRight, hasY = movesTop || movesBottom
            let scaleX = hasX ? abs((movesLeft ? minX : maxX) - anchorX) / r.width : 0
            let scaleY = hasY ? abs((movesTop ? minY : maxY) - anchorY) / r.height : 0
            let scale = max(scaleX, scaleY)
            let w = r.width * scale, h = r.height * scale
            // Corners grow away from the anchor; edge handles grow around the perpendicular center.
            let x: CGFloat = hasX ? (movesLeft ? r.maxX - w : r.minX) : r.midX - w / 2
            let y: CGFloat = hasY ? (movesTop ? r.maxY - h : r.minY) : r.midY - h / 2
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private static func withRect(_ kind: AnnotationKind, _ rect: CGRect) -> AnnotationKind {
        switch kind {
        case let .shape(k, _, filled): .shape(kind: k, rect: rect, filled: filled)
        case let .text(_, string, fontSize, bold, background):
            .text(frame: rect, string: string, fontSize: fontSize, bold: bold, background: background)
        case let .note(_, string, noteColor): .note(frame: rect, string: string, noteColor: noteColor)
        case let .blur(_, mode, strength): .blur(rect: rect, mode: mode, strength: strength)
        case .highlight: .highlight(rect: rect)
        case .arrow, .counter: kind
        }
    }

    /// Rotates so the rotation handle (above the top-center) points toward `p`.
    /// With `snap`, in steps of 15°.
    public static func rotated(_ a: Annotation, toward p: CGPoint, snap: Bool) -> Annotation {
        let box = bounds(a)
        var angle = atan2(p.y - box.midY, p.x - box.midX) + .pi / 2
        if snap {
            let step = Double.pi / 12
            angle = (angle / step).rounded() * step
        }
        var result = a
        result.rotation = angle
        return result
    }

    /// Snaps the direction from `s` to `e` to 45° steps, keeping the length.
    public static func snapAngle(from s: CGPoint, to e: CGPoint) -> CGPoint {
        let dx = e.x - s.x, dy = e.y - s.y
        let length = hypot(dx, dy)
        guard length > 0 else { return e }
        let k = Int((atan2(dy, dx) / (.pi / 4)).rounded())
        let d: CGFloat = CGFloat(0.5).squareRoot() // cos 45° == sin 45°, so diagonals are exact
        let directions: [CGPoint] = [
            CGPoint(x: 1, y: 0), CGPoint(x: d, y: d), CGPoint(x: 0, y: 1), CGPoint(x: -d, y: d),
            CGPoint(x: -1, y: 0), CGPoint(x: -d, y: -d), CGPoint(x: 0, y: -1), CGPoint(x: d, y: -d),
        ]
        let direction = directions[((k % 8) + 8) % 8]
        return CGPoint(x: s.x + direction.x * length, y: s.y + direction.y * length)
    }

    /// `proportional`: a square with the longer side, oriented in the drag direction.
    public static func constrainedRect(from s: CGPoint, to e: CGPoint, proportional: Bool) -> CGRect {
        var end = e
        if proportional {
            let dx = e.x - s.x, dy = e.y - s.y
            let side = max(abs(dx), abs(dy))
            end = CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
        }
        return CGRect(x: min(s.x, end.x), y: min(s.y, end.y), width: abs(end.x - s.x), height: abs(end.y - s.y))
    }

    public static func nextCounterNumber(in annotations: [Annotation], start: Int) -> Int {
        let highest = annotations.compactMap { a -> Int? in
            if case let .counter(_, number, _) = a.kind { number } else { nil }
        }.max()
        return highest.map { max(start, $0 + 1) } ?? start
    }
}
