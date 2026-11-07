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
    /// (clockwise on screen, y down), whatever order they were clicked in. Sorted by angle around their
    /// centroid, starting at the corner with the smallest x + y. Other counts are returned unchanged.
    public static func orderedClockwise(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count == 4 else { return points }
        let cx = points.map(\.x).reduce(0, +) / 4, cy = points.map(\.y).reduce(0, +) / 4
        let sorted = points.sorted { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
        guard let start = sorted.indices.min(by: { sorted[$0].x + sorted[$0].y < sorted[$1].x + sorted[$1].y })
        else { return points }
        return Array(sorted[start...] + sorted[..<start])
    }
}
