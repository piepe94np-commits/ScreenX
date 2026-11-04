import AppKit
import ScreenXCore

/// Zuschnitt-Werkzeug auf der Arbeitsfläche (die dann das ganze Original zeigt): Rahmen mit 8 Griffen,
/// außerhalb zu 50 % abgedunkelt. Griffe ändern die Größe, innen verschiebt ein Zug den Rahmen,
/// außerhalb zieht er einen neuen auf; ⇧ hält das Seitenverhältnis. Der Rahmen ist `vm.cropDraft`
/// und wird erst mit ↩ bzw. „Fertig“ zum Zuschnitt. Punkte in Ansichtspunkten, Rahmen in Pixeln des Originals.
@MainActor
enum CropInteraction {
    enum Part: Equatable {
        case handle(Handle)
        case move
        case new
    }

    static let handleSize: CGFloat = 8
    static let handleHitRadius: CGFloat = 8
    static let boxHandles: [Handle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

    /// Ein Zug am Rahmen, vom Drücken bis zum Loslassen.
    struct Drag {
        let part: Part
        let startRect: CGRect
        /// Druckpunkt in Pixeln des Originals.
        let start: CGPoint

        /// Der Rahmen für die Mausposition `p` (Pixel des Originals). Ein neuer Rahmen unter der
        /// Mindestgröße lässt den bisherigen stehen.
        func rect(to p: CGPoint, shift: Bool, bounds: CGRect) -> CGRect {
            switch part {
            case let .handle(handle):
                // Der Griff folgt der Maus mit dem Versatz, mit dem er gegriffen wurde.
                let grabbed = CropInteraction.point(of: handle, in: startRect)
                let target = CGPoint(x: p.x + grabbed.x - start.x, y: p.y + grabbed.y - start.y)
                return CropGeometry.resized(startRect, handle: handle, to: target, keepAspect: shift, in: bounds)
            case .move:
                var delta = CGVector(dx: p.x - start.x, dy: p.y - start.y)
                if shift {
                    if abs(delta.dx) >= abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 }
                }
                return CropGeometry.moved(startRect, by: delta, in: bounds)
            case .new:
                return CropGeometry.rect(from: start, to: p, square: shift, in: bounds) ?? startRect
            }
        }
    }

    /// Position eines Griffs am Rahmen `r` (gleiches Koordinatensystem wie `r`).
    static func point(of handle: Handle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        default: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// Rahmen `r` (Pixel des Originals) in Ansichtspunkten.
    static func viewRect(_ r: CGRect, mapping: CanvasMapping) -> CGRect {
        let a = mapping.toView(CGPoint(x: r.minX, y: r.minY))
        let b = mapping.toView(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Was ein Druck bei `point` bewegt: der nächste Griff, sonst innen der Rahmen, außen ein neuer.
    static func part(at point: CGPoint, draft: CGRect, mapping: CanvasMapping) -> Part {
        let frame = viewRect(draft, mapping: mapping)
        let nearest = boxHandles
            .map { (handle: $0, distance: hypot(Self.point(of: $0, in: frame).x - point.x,
                                                 Self.point(of: $0, in: frame).y - point.y)) }
            .filter { $0.distance <= handleHitRadius }
            .min { $0.distance < $1.distance }
        if let nearest { return .handle(nearest.handle) }
        return frame.contains(point) ? .move : .new
    }

    static func cursor(for part: Part, dragging: Bool) -> NSCursor {
        switch part {
        case let .handle(handle):
            let position: NSCursor.FrameResizePosition = switch handle {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            default: .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        case .move:
            return dragging ? .closedHand : .openHand
        case .new:
            return .crosshair
        }
    }

    /// Abdunklung des Bilds außerhalb des Rahmens, Rahmenlinie und Griffe.
    /// `imageCornerRadius` in Ansichtspunkten (die Abdunklung folgt den runden Ecken des Bilds).
    static func draw(draft: CGRect, bounds: CGRect, mapping: CanvasMapping, imageCornerRadius: CGFloat) {
        let image = viewRect(bounds, mapping: mapping)
        let frame = viewRect(draft, mapping: mapping)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: image, xRadius: imageCornerRadius, yRadius: imageCornerRadius).addClip()
        let dim = NSBezierPath(rect: image)
        dim.append(NSBezierPath(rect: frame))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()
        NSGraphicsContext.restoreGraphicsState()

        let outline = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        NSColor.white.setStroke()
        outline.stroke()

        let s = handleSize
        for handle in boxHandles {
            let p = point(of: handle, in: frame)
            let square = NSBezierPath(rect: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
            NSColor.white.setFill()
            square.fill()
            square.lineWidth = 1
            NSColor.black.withAlphaComponent(0.5).setStroke()
            square.stroke()
        }
    }
}
