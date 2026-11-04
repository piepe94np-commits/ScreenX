import CoreGraphics
import Foundation

/// Everything needed to render a beautified screenshot.
public struct RenderInput: Sendable {
    public var original: CGImage
    /// Crop in original pixels, origin top-left. `nil` uses the whole original.
    public var crop: CGRect?
    public var style: Style
    /// Decoded image for `Background.image`; ignored by other backgrounds.
    public var backgroundImage: CGImage?
    /// Drawn above the screenshot, in original pixels (origin top-left).
    public var annotations: [Annotation]
    /// Backing scale of the capture (`OriginalInfo.scale`); scales note text.
    public var originalScale: CGFloat

    public init(original: CGImage, crop: CGRect? = nil, style: Style, backgroundImage: CGImage? = nil,
                annotations: [Annotation] = [], originalScale: CGFloat = 1) {
        self.original = original
        self.crop = crop
        self.style = style
        self.backgroundImage = backgroundImage
        self.annotations = annotations
        self.originalScale = originalScale
    }
}

public enum Renderer {
    /// Renders background, shadow, the rounded (optionally cropped) screenshot and the annotations.
    /// Output size is `canvasSize × outputScale`, rounded; sRGB, premultiplied alpha.
    /// A crop that does not overlap the original is ignored (the whole original is shown).
    /// Returns `nil` only for a non-positive `outputScale` or if no context can be created.
    public static func render(_ input: RenderInput, outputScale: CGFloat = 1) -> CGImage? {
        guard outputScale > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: input.original.width, height: input.original.height)
        // Same clipping as `ImageCropper`, so the content and the annotation offset agree.
        var contentRect = bounds
        if let crop = input.crop {
            let clipped = crop.standardized.integral.intersection(bounds)
            if !clipped.isNull, !clipped.isEmpty { contentRect = clipped }
        }
        guard let content = contentRect == bounds ? input.original : input.original.cropping(to: contentRect)
        else { return nil }

        let style = input.style
        let layout = CanvasLayout.compute(
            contentSize: CGSize(width: content.width, height: content.height), style: style)
        let width = max(1, Int((layout.canvasSize.width * outputScale).rounded()))
        let height = max(1, Int((layout.canvasSize.height * outputScale).rounded()))

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.interpolationQuality = .high
        // Top-left origin, then draw in original-pixel units.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: outputScale, y: outputScale)

        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        BackgroundPainter.paint(style.background, in: ctx, canvas: canvas, original: input.original,
                                backgroundImage: input.backgroundImage, outputScale: outputScale)

        let rect = layout.imageRect
        let radius = max(0, min(CGFloat(style.cornerRadius), min(rect.width, rect.height) / 2))
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        let shadow = style.shadow.resolved()
        ctx.saveGState()
        if shadow.opacity > 0 {
            // Shadow offset and blur live in device space (y up, unscaled), unaffected by the CTM.
            ctx.setShadow(
                offset: CGSize(width: 0, height: -CGFloat(shadow.offsetY) * outputScale),
                blur: CGFloat(shadow.blur) * outputScale,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: min(1, shadow.opacity)))
        }
        // The shadow is cast by the clipped content itself (composited as one layer), so
        // transparent areas of the screenshot (e.g. window corners) stay free of shadow.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.drawUpright(content, in: rect)
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // After the image layer, so annotations do not cast the image's shadow.
        let originToCanvas = CGAffineTransform(translationX: rect.minX - contentRect.minX,
                                               y: rect.minY - contentRect.minY)
        AnnotationRenderer.draw(input.annotations, in: ctx, original: input.original,
                                originToCanvas: originToCanvas, clipRect: rect, clipRadius: radius,
                                originalScale: input.originalScale)

        return ctx.makeImage()
    }
}

extension CGContext {
    /// Draws `image` upright into `rect` of a context flipped to a top-left origin.
    func drawUpright(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}
