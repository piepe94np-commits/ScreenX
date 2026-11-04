import CoreGraphics
import Foundation

/// Geometry of the crop tool. Rects are in original pixels (origin top-left) and stay inside `bounds`
/// (the whole original); they are never smaller than `minimumSize` (or the original, if that is smaller).
public enum CropGeometry {
    /// Smallest crop, in original pixels.
    public static let minimumSize: CGFloat = 16

    /// The rect a crop tool starts with: the current crop (clipped and rounded) or the whole original.
    public static func initialRect(crop: CGRect?, bounds: CGRect) -> CGRect {
        guard let crop else { return bounds }
        let clipped = rounded(crop).intersection(bounds)
        guard !clipped.isNull, clipped.width >= minimum(bounds).width, clipped.height >= minimum(bounds).height
        else { return bounds }
        return clipped
    }

    /// Drags `handle` (one of the 8 box handles) of `r` to `point`. The opposite side stays fixed.
    /// `keepAspect` keeps the aspect ratio of `r`: corners scale away from the opposite corner,
    /// edge handles scale around the center of the perpendicular axis.
    public static func resized(_ r: CGRect, handle: Handle, to point: CGPoint, keepAspect: Bool,
                               in bounds: CGRect) -> CGRect {
        let p = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                        y: min(max(point.y, bounds.minY), bounds.maxY))
        let m = minimum(bounds)
        let left = [Handle.topLeft, .left, .bottomLeft].contains(handle)
        let right = [Handle.topRight, .right, .bottomRight].contains(handle)
        let top = [Handle.topLeft, .top, .topRight].contains(handle)
        let bottom = [Handle.bottomLeft, .bottom, .bottomRight].contains(handle)
        guard left || right || top || bottom else { return r }

        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if left { minX = min(p.x, maxX - m.width) }
        if right { maxX = max(p.x, minX + m.width) }
        if top { minY = min(p.y, maxY - m.height) }
        if bottom { maxY = max(p.y, minY + m.height) }
        guard keepAspect, r.width > 0, r.height > 0 else {
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        let ratio = r.width / r.height
        let hasX = left || right, hasY = top || bottom
        var w = maxX - minX, h = maxY - minY
        if hasX, hasY {
            if w / ratio > h { h = w / ratio } else { w = h * ratio }
        } else if hasX {
            h = w / ratio
        } else {
            w = h * ratio
        }
        if w < m.width { w = m.width; h = w / ratio }
        if h < m.height { h = m.height; w = h * ratio }

        // Fixed point: the opposite edge, or the center on an axis the handle does not move.
        let anchorX = left ? r.maxX : (right ? r.minX : r.midX)
        let anchorY = top ? r.maxY : (bottom ? r.minY : r.midY)
        let roomX = left ? anchorX - bounds.minX
            : (right ? bounds.maxX - anchorX : 2 * min(anchorX - bounds.minX, bounds.maxX - anchorX))
        let roomY = top ? anchorY - bounds.minY
            : (bottom ? bounds.maxY - anchorY : 2 * min(anchorY - bounds.minY, bounds.maxY - anchorY))
        let fit = min(1, roomX / w, roomY / h)
        w *= fit
        h *= fit
        let x = left ? anchorX - w : (right ? anchorX : anchorX - w / 2)
        let y = top ? anchorY - h : (bottom ? anchorY : anchorY - h / 2)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Moves `r` by `d`, stopping at the edges of `bounds`.
    public static func moved(_ r: CGRect, by d: CGVector, in bounds: CGRect) -> CGRect {
        let x = min(max(r.minX + d.dx, bounds.minX), bounds.maxX - r.width)
        let y = min(max(r.minY + d.dy, bounds.minY), bounds.maxY - r.height)
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }

    /// A new crop dragged from `s` to `e`, inside `bounds`. `square` makes it a square with the longer side.
    /// `nil` while it is smaller than the minimum size.
    public static func rect(from s: CGPoint, to e: CGPoint, square: Bool, in bounds: CGRect) -> CGRect? {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        let start = clamp(s)
        var end = clamp(e)
        if square {
            let dx = end.x - start.x, dy = end.y - start.y
            // The longest side that still fits in the drag direction.
            let roomX = dx < 0 ? start.x - bounds.minX : bounds.maxX - start.x
            let roomY = dy < 0 ? start.y - bounds.minY : bounds.maxY - start.y
            let side = min(max(abs(dx), abs(dy)), roomX, roomY)
            end = CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                       width: abs(end.x - start.x), height: abs(end.y - start.y))
        let m = minimum(bounds)
        return r.width >= m.width && r.height >= m.height ? r : nil
    }

    /// The crop to store: edges rounded to whole pixels (so canvas mapping and renderer agree),
    /// `nil` if it covers the whole original.
    public static func committed(_ r: CGRect, bounds: CGRect) -> CGRect? {
        let result = rounded(r).intersection(bounds)
        guard !result.isNull, result != bounds else { return nil }
        return result
    }

    private static func rounded(_ r: CGRect) -> CGRect {
        let s = r.standardized
        let minX = s.minX.rounded(), minY = s.minY.rounded()
        return CGRect(x: minX, y: minY, width: s.maxX.rounded() - minX, height: s.maxY.rounded() - minY)
    }

    private static func minimum(_ bounds: CGRect) -> CGSize {
        CGSize(width: min(minimumSize, bounds.width), height: min(minimumSize, bounds.height))
    }
}
