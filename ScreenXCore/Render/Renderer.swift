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
    /// Device template the content is placed into. `nil` renders without device, also when `placement`
    /// is set (missing template).
    public var template: DeviceTemplate?
    /// Fit, offset, fill color and URL text for `template`; `nil` uses the defaults.
    public var placement: TemplatePlacement?
    /// Frame image of a custom template (`.file` frame), scaled to the frame size.
    public var customFrameImage: CGImage?

    public init(original: CGImage, crop: CGRect? = nil, style: Style, backgroundImage: CGImage? = nil,
                annotations: [Annotation] = [], originalScale: CGFloat = 1, template: DeviceTemplate? = nil,
                placement: TemplatePlacement? = nil, customFrameImage: CGImage? = nil) {
        self.original = original
        self.crop = crop
        self.style = style
        self.backgroundImage = backgroundImage
        self.annotations = annotations
        self.originalScale = originalScale
        self.template = template
        self.placement = placement
        self.customFrameImage = customFrameImage
    }
}

public enum Renderer {
    /// Renders background, shadow, the rounded (optionally cropped) screenshot and the annotations.
    /// With a template or a tilt, the content (with its annotations) is first placed into the device
    /// and/or tilted, see `renderDevice`; the canvas then uses `DeviceCompositor.layout`.
    /// Output size is `canvasSize × outputScale`, rounded; sRGB, premultiplied alpha.
    /// A crop that does not overlap the original is ignored (the whole original is shown).
    /// Returns `nil` only for a non-positive `outputScale` or if no context can be created.
    public static func render(_ input: RenderInput, outputScale: CGFloat = 1) -> CGImage? {
        guard outputScale > 0 else { return nil }
        let contentRect = Self.contentRect(for: input)
        let bounds = CGRect(x: 0, y: 0, width: input.original.width, height: input.original.height)
        guard let content = contentRect == bounds ? input.original : input.original.cropping(to: contentRect)
        else { return nil }

        let style = input.style
        let resolved = Self.layout(for: input)
        let layout = resolved.canvas
        if let device = resolved.device {
            return renderDevice(input, content: content, contentRect: contentRect, layout: layout, device: device,
                                outputScale: outputScale)
        }
        guard let ctx = canvasContext(size: layout.canvasSize, outputScale: outputScale) else { return nil }

        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        BackgroundPainter.paint(style.background, in: ctx, canvas: canvas, original: input.original,
                                backgroundImage: input.backgroundImage, outputScale: outputScale)

        let rect = layout.imageRect
        let radius = max(0, min(CGFloat(style.cornerRadius), min(rect.width, rect.height) / 2))
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        setShadow(style.shadow, in: ctx, outputScale: outputScale)
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

    /// The canvas layout `render` uses, in canvas units (original pixels).
    /// - `device` is non-nil exactly when the device path is used: a template is set or the (clamped)
    ///   tilt is not zero. Then `canvas` is `CanvasLayout.compute(contentSize: device.imageSize, style:)`.
    /// - Otherwise `canvas` is computed from the crop size.
    /// The content is the crop clipped to the original (integral; a non-overlapping crop means the whole
    /// original), as in `ImageCropper`. With a template and no tilt, a canvas point minus
    /// `canvas.imageRect.origin` is a device-image point for
    /// `TemplateGeometry.screenToContentTransform(…, frameScale: device.frameScale)`.
    public static func layout(for input: RenderInput) -> (canvas: CanvasLayout, device: DeviceLayout?) {
        let contentSize = contentRect(for: input).size
        let style = input.style
        guard input.template != nil || TemplateGeometry.clamped(style.tilt) != .zero else {
            return (CanvasLayout.compute(contentSize: contentSize, style: style), nil)
        }
        let device = DeviceCompositor.layout(template: input.template, contentSize: contentSize, tilt: style.tilt)
        return (CanvasLayout.compute(contentSize: device.imageSize, style: style), device)
    }

    /// The crop clipped to the original, integral; the whole original without (overlapping) crop.
    /// Same clipping as `ImageCropper`, so the content and the annotation offset agree.
    private static func contentRect(for input: RenderInput) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: input.original.width, height: input.original.height)
        if let crop = input.crop {
            let clipped = crop.standardized.integral.intersection(bounds)
            if !clipped.isNull, !clipped.isEmpty { return clipped }
        }
        return bounds
    }

    /// sRGB, premultiplied alpha, `size × outputScale` pixels (rounded); user space flipped to a top-left
    /// origin and scaled to canvas units.
    private static func canvasContext(size: CGSize, outputScale: CGFloat) -> CGContext? {
        let width = max(1, Int((size.width * outputScale).rounded()))
        let height = max(1, Int((size.height * outputScale).rounded()))
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
        return ctx
    }

    private static func setShadow(_ style: ShadowStyle, in ctx: CGContext, outputScale: CGFloat) {
        let shadow = style.resolved()
        guard shadow.opacity > 0 else { return }
        // Shadow offset and blur live in device space (y up, unscaled), unaffected by the CTM.
        ctx.setShadow(
            offset: CGSize(width: 0, height: -CGFloat(shadow.offsetY) * outputScale),
            blur: CGFloat(shadow.blur) * outputScale,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: min(1, shadow.opacity)))
    }

    /// Device template and/or tilt (Task M4):
    /// 1. content = crop plus annotations, at output resolution (annotations follow the device, R2);
    ///    without template the corner radius is applied here, before the tilt
    /// 2. with template: `DeviceCompositor.compose` (the corner radius does not apply)
    /// 3. with tilt: `DeviceCompositor.tilted`
    /// 4. the result is the image for `CanvasLayout`: background, padding, shadow from its alpha.
    private static func renderDevice(_ input: RenderInput, content: CGImage, contentRect: CGRect,
                                     layout: CanvasLayout, device: DeviceLayout, outputScale: CGFloat) -> CGImage? {
        let style = input.style
        let template = input.template
        let contentSize = contentRect.size
        let radius = template == nil
            ? max(0, min(CGFloat(style.cornerRadius), min(contentSize.width, contentSize.height) / 2)) : 0

        guard var image = screenContent(input, content: content, contentRect: contentRect, radius: radius,
                                        outputScale: outputScale) else { return nil }
        if let template {
            let placement = input.placement ?? TemplatePlacement(templateID: template.id)
            guard let composed = DeviceCompositor.compose(
                content: image, template: template, placement: placement, customFrame: input.customFrameImage,
                scale: device.frameScale * outputScale) else { return nil }
            image = composed
        }
        guard let tilted = DeviceCompositor.tilted(image, tilt: style.tilt) else { return nil }
        image = tilted

        guard let ctx = canvasContext(size: layout.canvasSize, outputScale: outputScale) else { return nil }
        BackgroundPainter.paint(style.background, in: ctx, canvas: CGRect(origin: .zero, size: layout.canvasSize),
                                original: input.original, backgroundImage: input.backgroundImage,
                                outputScale: outputScale)
        ctx.saveGState()
        setShadow(style.shadow, in: ctx, outputScale: outputScale)
        // The shadow follows the image's alpha (device outline, tilted shape), not a rectangle.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // `image` has whole pixels (device: rounded frame size; tilt: integral bounding box of the corners),
        // while `imageRect` has the exact size from `DeviceLayout`. Drawing it into `imageRect` stretches it
        // by less than one output pixel, so the screen lands where `screenToContentTransform` expects it.
        ctx.drawUpright(image, in: layout.imageRect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// The cropped screenshot with its annotations, `contentRect.size × outputScale` pixels (rounded),
    /// clipped to a rounded rectangle with `radius` (content units).
    private static func screenContent(_ input: RenderInput, content: CGImage, contentRect: CGRect,
                                      radius: CGFloat, outputScale: CGFloat) -> CGImage? {
        let size = contentRect.size
        let width = max(1, Int((size.width * outputScale).rounded()))
        let height = max(1, Int((size.height * outputScale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)

        let rect = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.drawUpright(content, in: rect)
        ctx.restoreGState()
        AnnotationRenderer.draw(input.annotations, in: ctx, original: input.original,
                                originToCanvas: CGAffineTransform(translationX: -contentRect.minX,
                                                                  y: -contentRect.minY),
                                clipRect: rect, clipRadius: radius, originalScale: input.originalScale)
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
