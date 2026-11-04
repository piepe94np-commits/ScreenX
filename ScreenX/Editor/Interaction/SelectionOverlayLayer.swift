import AppKit
import ScreenXCore

/// Auswahl-Darstellung über der Vorschau, in Ansichtspunkten einer gespiegelten Ansicht (Ursprung oben links):
/// gestrichelte Bounds der ausgewählten Anmerkungen, bei genau einer Auswahl Griffe als 8-pt-Kreise und
/// der Rotationsgriff mit Linie, dazu der Rahmen einer laufenden Rahmen-Auswahl.
///
/// Gezeichnet wird in `draw(_:)` der Interaktionsansicht statt in einem eigenen `CALayer`: so gilt das
/// gespiegelte Koordinatensystem der Ansicht ohne Annahmen über `geometryFlipped` der Ebenen.
@MainActor
struct SelectionOverlayLayer {
    static let handleDiameter: CGFloat = 8
    /// Trefferradius der Griffe in Ansichtspunkten (etwas größer als der sichtbare Kreis).
    static let handleHitRadius: CGFloat = 7

    let selected: [Annotation]
    let mapping: CanvasMapping
    var marquee: CGRect?

    /// Griffe werden nur bei genau einer ausgewählten Anmerkung gezeigt und bedient.
    var handleTarget: Annotation? { selected.count == 1 ? selected[0] : nil }

    /// Bedienbare Griffe einer Anmerkung in Ansichtspunkten (gedreht). Unschärfe dreht sich nicht.
    static func handles(for a: Annotation, mapping: CanvasMapping) -> [(handle: Handle, point: CGPoint)] {
        let isBlur: Bool
        if case .blur = a.kind { isBlur = true } else { isBlur = false }
        return AnnotationGeometry.handles(for: a)
            .filter { !(isBlur && $0.key == .rotate) }
            .map { (handle: $0.key, point: mapping.toView(AnnotationGeometry.toOriginal($0.value, of: a))) }
    }

    /// Nächster Griff innerhalb von `handleHitRadius` um `point` (Ansichtspunkte).
    static func handle(at point: CGPoint, of a: Annotation, mapping: CanvasMapping) -> Handle? {
        handles(for: a, mapping: mapping)
            .map { (handle: $0.handle, distance: hypot($0.point.x - point.x, $0.point.y - point.y)) }
            .filter { $0.distance <= handleHitRadius }
            .min { $0.distance < $1.distance }?
            .handle
    }

    func draw() {
        let accent = NSColor.controlAccentColor
        for annotation in selected where !(handleTarget != nil && Self.hasEndpoints(annotation)) {
            let corners = AnnotationGeometry.outline(of: annotation).map(mapping.toView)
            let path = NSBezierPath()
            path.move(to: corners[0])
            for corner in corners.dropFirst() { path.line(to: corner) }
            path.close()
            strokeDashed(path, color: accent)
        }

        if let target = handleTarget {
            let handles = Self.handles(for: target, mapping: mapping)
            if let rotate = handles.first(where: { $0.handle == .rotate })?.point {
                let box = AnnotationGeometry.bounds(target)
                let topCenter = mapping.toView(
                    AnnotationGeometry.toOriginal(CGPoint(x: box.midX, y: box.minY), of: target))
                let line = NSBezierPath()
                line.move(to: topCenter)
                line.line(to: rotate)
                line.lineWidth = 1
                accent.setStroke()
                line.stroke()
            }
            for (_, point) in handles { drawHandle(at: point, color: accent) }
        }

        if let marquee {
            let path = NSBezierPath(rect: marquee.insetBy(dx: 0.5, dy: 0.5))
            accent.withAlphaComponent(0.12).setFill()
            path.fill()
            path.lineWidth = 1
            accent.setStroke()
            path.stroke()
        }
    }

    /// Pfeile und Linien zeigen bei Einzelauswahl nur ihre Endpunkte, keinen Rahmen.
    private static func hasEndpoints(_ a: Annotation) -> Bool {
        switch a.kind {
        case .arrow, .shape(.line, _, _): true
        default: false
        }
    }

    /// Weiß unterlegt, damit die Strichelung auf hellem und dunklem Grund sichtbar bleibt.
    private func strokeDashed(_ path: NSBezierPath, color: NSColor) {
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
        path.setLineDash([4, 3], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
        path.setLineDash(nil, count: 0, phase: 0)
    }

    private func drawHandle(at point: CGPoint, color: NSColor) {
        let d = Self.handleDiameter
        let circle = NSBezierPath(ovalIn: CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d))
        NSColor.white.setFill()
        circle.fill()
        circle.lineWidth = 1.5
        color.setStroke()
        circle.stroke()
    }
}
