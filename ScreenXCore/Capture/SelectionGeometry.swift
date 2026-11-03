import CoreGraphics

public enum SelectionGeometry {
    public static let minimumSize: CGFloat = 4

    /// Rechteck aus einer Ziehbewegung. Mit `square` ist die Seite die längere Ausdehnung,
    /// das Quadrat wächst in Zugrichtung von `start` aus.
    public static func rect(from start: CGPoint, to end: CGPoint, square: Bool) -> CGRect {
        var target = end
        if square {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let side = max(abs(dx), abs(dy))
            target = CGPoint(
                x: start.x + (dx < 0 ? -side : side),
                y: start.y + (dy < 0 ? -side : side)
            )
        }
        return CGRect(
            x: min(start.x, target.x),
            y: min(start.y, target.y),
            width: abs(target.x - start.x),
            height: abs(target.y - start.y)
        )
    }

    /// Schnittmenge mit `bounds`; `.null`, wenn sich beide nicht überlappen.
    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        rect.standardized.intersection(bounds.standardized)
    }

    public static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.width >= minimumSize && rect.height >= minimumSize
    }

    /// `globalRect` in AppKit-Global-Koordinaten (unten links) → Pixelrechteck im Bild des Monitors
    /// (Ursprung oben links), nach außen auf ganze Pixel gerundet und auf die Bildgröße begrenzt.
    public static func pixelRect(for globalRect: CGRect, on display: DisplayInfo) -> CGRect {
        let r = globalRect.standardized
        let local = CGRect(
            x: (r.minX - display.frame.minX) * display.scale,
            y: (display.frame.maxY - r.maxY) * display.scale,
            width: r.width * display.scale,
            height: r.height * display.scale
        ).integral
        let imageBounds = CGRect(
            x: 0, y: 0,
            width: display.frame.width * display.scale,
            height: display.frame.height * display.scale
        )
        return local.intersection(imageBounds)
    }
}
