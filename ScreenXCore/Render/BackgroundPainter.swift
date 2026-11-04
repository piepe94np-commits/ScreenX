import CoreGraphics
import CoreImage
import Foundation

/// Paints a `Background` into a context flipped to a top-left origin, in original-pixel units.
enum BackgroundPainter {
    static func paint(_ background: Background, in ctx: CGContext, canvas: CGRect, original: CGImage,
                      backgroundImage: CGImage?, outputScale: CGFloat) {
        switch background {
        case let .gradient(stops, angle):
            paintGradient(stops: stops, angle: angle, in: ctx, canvas: canvas)
        case let .solid(color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(canvas)
        case .image:
            guard let image = backgroundImage else { return }
            paintAspectFill(image, in: ctx, canvas: canvas)
        case let .blurredScreenshot(radius):
            guard let blurred = blur(original, radius: radius, outputScale: outputScale) else { return }
            ctx.drawUpright(blurred, in: canvas)
        case .none:
            break
        }
    }

    /// CSS `linear-gradient` semantics: 0° points up, 90° right; the gradient line passes
    /// through the center with length |w·sinθ| + |h·cosθ|.
    private static func paintGradient(stops: [GradientStop], angle: Double, in ctx: CGContext, canvas: CGRect) {
        let sorted = stops.sorted { $0.location < $1.location }
        guard let first = sorted.first else { return }
        if sorted.count == 1 {
            ctx.setFillColor(first.color.cgColor)
            ctx.fill(canvas)
            return
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(
                colorsSpace: space,
                colors: sorted.map(\.color.cgColor) as CFArray,
                locations: sorted.map { CGFloat($0.location) })
        else { return }

        let theta = angle * .pi / 180
        // Direction in y-down space.
        let dx = CGFloat(sin(theta)), dy = CGFloat(-cos(theta))
        let length = abs(canvas.width * dx) + abs(canvas.height * dy)
        let center = CGPoint(x: canvas.midX, y: canvas.midY)
        let start = CGPoint(x: center.x - dx * length / 2, y: center.y - dy * length / 2)
        let end = CGPoint(x: center.x + dx * length / 2, y: center.y + dy * length / 2)

        ctx.saveGState()
        ctx.clip(to: canvas)
        ctx.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func paintAspectFill(_ image: CGImage, in ctx: CGContext, canvas: CGRect) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return }
        let scale = max(canvas.width / w, canvas.height / h)
        let size = CGSize(width: w * scale, height: h * scale)
        let rect = CGRect(x: canvas.midX - size.width / 2, y: canvas.midY - size.height / 2,
                          width: size.width, height: size.height)
        ctx.saveGState()
        ctx.clip(to: canvas)
        ctx.drawUpright(image, in: rect)
        ctx.restoreGState()
    }

    /// Gaussian blur at output resolution (radius × outputScale), edges clamped.
    private static func blur(_ image: CGImage, radius: Double, outputScale: CGFloat) -> CGImage? {
        let source = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: outputScale, y: outputScale))
        let extent = source.extent.integral
        let blurred = radius > 0
            ? source.clampedToExtent().applyingGaussianBlur(sigma: radius * Double(outputScale)).cropped(to: extent)
            : source
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(blurred, from: extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
