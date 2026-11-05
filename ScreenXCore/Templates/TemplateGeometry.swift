import CoreGraphics
import Foundation

/// Geometry for placing content into a device template: fill/fit, frame scale, aspect hint and tilt.
public enum TemplateGeometry {
    /// Part of the content (`source`, content pixels) drawn into which part of the screen
    /// (`dest`, screen coordinates with origin at the screen's top-left).
    /// - `.fill`: crop with the screen's aspect, centered and moved by `offset` (each axis -1…1,
    ///   clamped, non-finite counts as 0) across the free range; `dest` is the whole screen.
    /// - `.fit`: `source` is the whole content; `dest` is the content fitted and centered.
    public static func sourceRect(contentSize: CGSize, screenSize: CGSize, fit: FitMode,
                                  offset: CGPoint) -> (source: CGRect, dest: CGRect) {
        let content = CGRect(origin: .zero, size: contentSize)
        let screen = CGRect(origin: .zero, size: screenSize)
        guard contentSize.width > 0, contentSize.height > 0, screenSize.width > 0, screenSize.height > 0 else {
            return (content, screen)
        }
        switch fit {
        case .fill:
            // The axis the content is wider in is cropped; the other keeps its exact length.
            let screenAspect = screenSize.width / screenSize.height
            let contentIsWider = contentSize.width / contentSize.height > screenAspect
            let w = contentIsWider ? contentSize.height * screenAspect : contentSize.width
            let h = contentIsWider ? contentSize.height : contentSize.width / screenAspect
            let freeX = contentSize.width - w, freeY = contentSize.height - h
            func clamp(_ v: CGFloat) -> CGFloat { v.isFinite ? min(max(v, -1), 1) : 0 }
            let ox = clamp(offset.x), oy = clamp(offset.y)
            let source = CGRect(x: freeX / 2 * (1 + ox), y: freeY / 2 * (1 + oy), width: w, height: h)
            return (source, screen)
        case .fit:
            let scale = min(screenSize.width / contentSize.width, screenSize.height / contentSize.height)
            let w = contentSize.width * scale, h = contentSize.height * scale
            let dest = CGRect(x: (screenSize.width - w) / 2, y: (screenSize.height - h) / 2, width: w, height: h)
            return (content, dest)
        }
    }

    /// Scale of the frame so the screen width (quad bounds) equals the content width in pixels,
    /// clamped to 0.25…4.
    public static func frameScale(template: DeviceTemplate, contentSize: CGSize) -> CGFloat {
        let screenWidth = template.screenBounds.width
        guard screenWidth > 0, contentSize.width > 0 else { return 1 }
        return min(max(contentSize.width / screenWidth, 0.25), 4)
    }

    /// Relative aspect deviation `|c/p − 1|`; `nil` without (valid) `preferred` aspect.
    public static func aspectMismatch(contentSize: CGSize, preferred: [Int]?) -> Double? {
        guard let preferred, preferred.count == 2, preferred[0] > 0, preferred[1] > 0,
              contentSize.width > 0, contentSize.height > 0 else { return nil }
        let c = Double(contentSize.width / contentSize.height)
        let p = Double(preferred[0]) / Double(preferred[1])
        return abs(c / p - 1)
    }

    /// Readable aspect such as „16:10“ or „9:19,5“. Small values are shown as given; otherwise the
    /// ratio is reduced, and if it is still large, the smaller side is normalized to 9
    /// (one decimal, German comma).
    public static func recommendedAspectText(_ preferred: [Int]) -> String {
        guard preferred.count == 2, preferred[0] > 0, preferred[1] > 0 else { return "" }
        var w = preferred[0], h = preferred[1]
        if max(w, h) > 32 {
            let d = gcd(w, h)
            w /= d
            h /= d
        }
        if max(w, h) <= 32 { return "\(w):\(h)" }
        let ratio = Double(max(w, h)) / Double(min(w, h)) * 9
        let large = String(format: "%.1f", locale: Locale(identifier: "de_DE"), ratio)
            .replacingOccurrences(of: ",0", with: "")
        return w < h ? "9:\(large)" : "\(large):9"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }

    /// Corners (top-left, top-right, bottom-right, bottom-left) of a `size` rectangle after a 3D tilt.
    ///
    /// Composition (Task 4 must reproduce it exactly):
    /// 1. Center the rectangle at the origin (y down, z away from the viewer).
    /// 2. Rotate in object space first around the X axis by `tilt.x`:
    ///    `y' = y·cos, z' = −y·sin`. Positive x tilts the top edge away from the viewer.
    /// 3. Then rotate around the Y axis by `tilt.y`: `x'' = x'·cos − z'·sin, z'' = x'·sin + z'·cos`.
    ///    Positive y tilts the right edge away from the viewer.
    /// 4. Project with the viewer at distance `d = 2.5 × max(w, h)`: `f = d / (d + z'')`,
    ///    giving `(x''·f, y'·f)`.
    /// 5. Shift so the smallest x and y are 0.
    ///
    /// Tilt values are clamped to ±30°, and non-finite values count as 0 (see `clamped(_:)`).
        public static func tiltCorners(size: CGSize, tilt: Tilt) -> [CGPoint] {
        let w = Double(size.width), h = Double(size.height)
        let d = 2.5 * max(w, h)
        let t = clamped(tilt)
        let ax = t.x * .pi / 180, ay = t.y * .pi / 180
        let corners: [(Double, Double)] = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
        let projected = corners.map { corner -> (Double, Double) in
            let (x0, y0) = corner
            // Around X (z0 = 0): the top edge (y < 0) moves away from the viewer for positive x tilt.
            let y1 = y0 * cos(ax)
            let z1 = -y0 * sin(ax)
            // Around Y, a proper rotation (det 1): the right edge (x > 0) moves away for positive y tilt.
            let x2 = x0 * cos(ay) - z1 * sin(ay)
            let z2 = x0 * sin(ay) + z1 * cos(ay)
            // |z2| ≤ half diagonal < d, so the corner stays in front of the viewer.
            let f = d > 0 ? d / (d + z2) : 1
            return (x2 * f, y1 * f)
        }
        let minX = projected.map(\.0).min() ?? 0, minY = projected.map(\.1).min() ?? 0
        return projected.map { CGPoint(x: $0.0 - minX, y: $0.1 - minY) }
    }

    /// Maximum tilt per axis in degrees.
    public static let maxTilt = 30.0

    /// `tilt` with each axis clamped to ±`maxTilt`; non-finite values count as 0.
    public static func clamped(_ tilt: Tilt) -> Tilt {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, -maxTilt), maxTilt) : 0 }
        return Tilt(x: clamp(tilt.x), y: clamp(tilt.y))
    }

    /// Annotations can be edited only while content maps affinely onto the canvas:
    /// no (clamped) tilt and, with a template, a rectangular screen quad.
    public static func isAffineEditable(template: DeviceTemplate?, tilt: Tilt) -> Bool {
        clamped(tilt) == .zero && (template?.isRectangular ?? true)
    }

    /// Maps a point in the composed device image to content pixels.
    /// - Input: device-image pixels, i.e. frame units × `frameScale`, origin at the frame's top-left,
    ///   before the image is placed on the canvas (no padding or alignment offset).
    /// - Output: pixels of the content passed as `contentSize`, i.e. the cropped screen content,
    ///   origin at the crop's top-left.
    /// - `frameScale` must be the value the renderer used, `frameScale(template:contentSize:)`.
    /// Returns `nil` when the screen quad is not rectangular. Tilt is not part of this mapping;
    /// check `isAffineEditable` first.
    public static func screenToContentTransform(template: DeviceTemplate, placement: TemplatePlacement,
                                                contentSize: CGSize, frameScale: CGFloat) -> CGAffineTransform? {
        guard template.isRectangular, frameScale > 0 else { return nil }
        let screen = template.screenBounds
        let (source, dest) = sourceRect(contentSize: contentSize, screenSize: screen.size,
                                        fit: placement.fit, offset: placement.offset)
        guard dest.width > 0, dest.height > 0 else { return nil }
        let sx = source.width / dest.width, sy = source.height / dest.height
        // device image → frame units → screen-local → dest-local → content pixels
        return CGAffineTransform(scaleX: 1 / frameScale, y: 1 / frameScale)
            .concatenating(CGAffineTransform(translationX: -screen.minX - dest.minX, y: -screen.minY - dest.minY))
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: source.minX, y: source.minY))
    }
}
