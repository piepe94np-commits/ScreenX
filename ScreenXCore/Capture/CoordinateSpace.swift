import CoreGraphics

/// Umrechnung zwischen AppKit-global (Ursprung unten links des Hauptbildschirms, y nach oben)
/// und global oben links (ScreenCaptureKit/CGWindow, y nach unten).
public enum CoordinateSpace {
    /// `primaryHeight` ist die Höhe des Bildschirms mit Ursprung (0,0).
    public static func toTopLeft(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    public static func toTopLeft(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Umkehrung von `toTopLeft`: global oben links → AppKit-global (unten links).
    public static func toBottomLeft(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
