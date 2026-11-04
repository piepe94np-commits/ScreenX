import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Draws annotations into a context flipped to a top-left origin (as set up by `Renderer`).
public enum AnnotationRenderer {
    static let textBackgroundPadding: CGFloat = 6
    static let textBackgroundRadius: CGFloat = 6
    static let noteRadius: CGFloat = 4
    static let highlightOpacity: Double = 0.4

    /// Draws `annotations` in array order (last on top).
    ///
    /// - Parameters:
    ///   - originToCanvas: maps original pixels to canvas pixels (crop offset plus `imageRect.origin`).
    ///   - clipRect: the image rectangle on the canvas. Blur and highlight are clipped to it (rounded with
    ///     `clipRadius`); arrows, shapes, text, notes and counters may extend beyond it and are only
    ///     limited by the canvas (the context's bounds).
    ///   - originalScale: the capture's backing scale; note text is `15 × originalScale` pixels.
    public static func draw(_ annotations: [Annotation], in ctx: CGContext, original: CGImage,
                            originToCanvas: CGAffineTransform, clipRect: CGRect,
                            clipRadius: CGFloat = 0, originalScale: CGFloat = 1) {
        guard !annotations.isEmpty else { return }
        let imageClip = CGPath(roundedRect: clipRect, cornerWidth: clipRadius, cornerHeight: clipRadius,
                               transform: nil)
        // Shadow offset and blur live in device space (unaffected by the CTM): map the note shadow's
        // "4 px down" and its softness through the canvas-to-device transform.
        let base = ctx.ctm
        let noteShadowOffset = CGSize(width: 4 * base.c, height: 4 * base.d)
        let noteShadowBlur = 12 * sqrt(abs(base.a * base.d - base.b * base.c))

        // The visible part of the original (the crop), in original pixels.
        let visible = clipRect.applying(originToCanvas.inverted())

        for annotation in annotations where intersects(annotation, visible) {
            ctx.saveGState()
            switch annotation.kind {
            case .blur, .highlight:
                ctx.addPath(imageClip)
                ctx.clip()
            default:
                break
            }
            ctx.concatenate(originToCanvas)
            if annotation.rotation != 0 {
                let box = AnnotationGeometry.bounds(annotation)
                ctx.translateBy(x: box.midX, y: box.midY)
                ctx.rotate(by: CGFloat(annotation.rotation))
                ctx.translateBy(x: -box.midX, y: -box.midY)
            }
            draw(annotation, in: ctx, original: original, originalScale: originalScale,
                 noteShadowOffset: noteShadowOffset, noteShadowBlur: noteShadowBlur)
            ctx.restoreGState()
        }
    }

    /// Whether the rotated bounding box (widened by half the stroke) meets `visible`. Annotations lying
    /// entirely in the cropped-away area are skipped, so they cannot show up in the padding.
    private static func intersects(_ a: Annotation, _ visible: CGRect) -> Bool {
        let box = AnnotationGeometry.bounds(a)
        let half = max(CGFloat(a.strokeWidth) / 2, 1)
        var rotated = box
        if a.rotation != 0 {
            let rotation = CGAffineTransform(translationX: box.midX, y: box.midY)
                .rotated(by: CGFloat(a.rotation))
                .translatedBy(x: -box.midX, y: -box.midY)
            rotated = box.applying(rotation)
        }
        return rotated.insetBy(dx: -half, dy: -half).intersects(visible)
    }

    private static func draw(_ a: Annotation, in ctx: CGContext, original: CGImage, originalScale: CGFloat,
                             noteShadowOffset: CGSize, noteShadowBlur: CGFloat) {
        let color = a.color.cgColor
        let lineWidth = CGFloat(a.strokeWidth)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case let .arrow(start, end, control, head):
            let arrow = ArrowPath(start: start, end: end, control: control, head: head, strokeWidth: a.strokeWidth)
            if let shaft = arrow.shaft {
                ctx.addPath(shaft)
                ctx.strokePath()
            }
            for path in arrow.heads {
                ctx.addPath(path)
                if arrow.headsFilled { ctx.fillPath() } else { ctx.strokePath() }
            }

        case let .shape(kind, rect, filled):
            drawShape(kind, rect: rect, filled: filled, in: ctx)

        case let .text(frame, string, _, _, background):
            let frame = frame.standardized
            guard let style = AnnotationTextLayout.textStyle(of: a, originalScale: originalScale) else { return }
            let font = systemFont(size: style.fontSize, bold: style.bold)
            let textHeight = measure(string, font: font, width: frame.width).height
            if let background {
                let box = CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                                 height: max(frame.height, textHeight))
                    .insetBy(dx: -textBackgroundPadding, dy: -textBackgroundPadding)
                ctx.setFillColor(background.cgColor)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: textBackgroundRadius,
                                   cornerHeight: textBackgroundRadius, transform: nil))
                ctx.fillPath()
            }
            drawText(string, font: font, color: color, in: frame, ctx: ctx)

        case let .note(frame, string, noteColor):
            let frame = frame.standardized
            let shape = CGPath(roundedRect: frame, cornerWidth: min(noteRadius, frame.width / 2),
                               cornerHeight: min(noteRadius, frame.height / 2), transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: noteShadowOffset, blur: noteShadowBlur,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
            ctx.setFillColor(noteColor.cgColor)
            ctx.addPath(shape)
            ctx.fillPath()
            ctx.restoreGState()
            guard let style = AnnotationTextLayout.textStyle(of: a, originalScale: originalScale),
                  let textRect = AnnotationTextLayout.textRect(of: a) else { return }
            drawText(string, font: systemFont(size: style.fontSize, bold: style.bold), color: style.color.cgColor,
                     in: textRect, ctx: ctx)

        case let .counter(center, number, radius):
            let r = CGFloat(radius)
            guard r > 0 else { return }
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            drawCenteredLine(String(number), font: systemFont(size: r * 1.1, bold: true),
                             color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), center: center, ctx: ctx)

        case let .blur(rect, mode, strength):
            let bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
            let piece = rect.standardized.integral.intersection(bounds)
            guard !piece.isNull, !piece.isEmpty,
                  let image = blurred(original, rect: piece, mode: mode, strength: strength) else { return }
            // Keep pixelate blocks crisp when the output is scaled (e.g. @2x export).
            if mode == .pixelate { ctx.interpolationQuality = .none }
            ctx.drawUpright(image, in: piece)

        case let .highlight(rect):
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(a.color.cgColor.copy(alpha: CGFloat(a.color.alpha * highlightOpacity)) ?? color)
            ctx.fill(rect.standardized)
        }
    }

    private static func drawShape(_ kind: ShapeKind, rect: CGRect, filled: Bool, in ctx: CGContext) {
        let r = rect.standardized
        let path: CGPath
        switch kind {
        case .rectangle:
            path = CGPath(rect: r, transform: nil)
        case .roundedRectangle:
            let radius = min(r.width, r.height) * 0.15
            path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse:
            path = CGPath(ellipseIn: r, transform: nil)
        case .line:
            // Start and end are opposite corners of the unstandardized rect.
            let line = CGMutablePath()
            line.move(to: rect.origin)
            line.addLine(to: CGPoint(x: rect.origin.x + rect.size.width, y: rect.origin.y + rect.size.height))
            ctx.addPath(line)
            ctx.strokePath()
            return
        }
        if kind == .rectangle { ctx.setLineJoin(.miter) }
        ctx.addPath(path)
        if filled { ctx.fillPath() } else { ctx.strokePath() }
    }

    // MARK: Text

    static func systemFont(size: CGFloat, bold: Bool) -> CTFont {
        AnnotationTextLayout.systemFont(size: size, bold: bold)
    }

    private static func attributed(_ string: String, font: CTFont, color: CGColor) -> CFAttributedString {
        AnnotationTextLayout.attributed(string, font: font, color: color)
    }

    static func measure(_ string: String, font: CTFont, width: CGFloat) -> CGSize {
        AnnotationTextLayout.measure(string, font: font, width: width)
    }

    /// Lays `string` out from the top of `frame`, wrapped to its width. Text taller than the frame
    /// is not cut off.
    private static func drawText(_ string: String, font: CTFont, color: CGColor, in frame: CGRect, ctx: CGContext) {
        guard !string.isEmpty, frame.width > 0 else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(string, font: font, color: color))
        let height = max(frame.height, ceil(measure(string, font: font, width: frame.width).height) + 1)
        ctx.saveGState()
        // Core Text draws in a y-up space: flip locally with the origin at the frame's top-left,
        // so the layout box (height `height`) hangs down from the top edge.
        ctx.translateBy(x: frame.minX, y: frame.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let box = CGRect(x: 0, y: -height, width: frame.width, height: height)
        let textFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                                 CGPath(rect: box, transform: nil), nil)
        CTFrameDraw(textFrame, ctx)
        ctx.restoreGState()
    }

    /// One line of text, centered on `center` (glyph bounds, so digits sit optically centered).
    private static func drawCenteredLine(_ string: String, font: CTFont, color: CGColor, center: CGPoint,
                                         ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(attributed(string, font: font, color: color))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Blur

    /// The blurred or pixelated `rect` of the original (integral, origin top-left, inside the original).
    private static func blurred(_ original: CGImage, rect: CGRect, mode: BlurMode, strength: Double) -> CGImage? {
        guard let piece = original.cropping(to: rect) else { return nil }
        let source = CIImage(cgImage: piece)
        let extent = source.extent
        let output: CIImage
        switch mode {
        case .blur:
            guard strength > 0 else { return piece }
            output = source.clampedToExtent().applyingGaussianBlur(sigma: strength).cropped(to: extent)
        case .pixelate:
            guard let filter = CIFilter(name: "CIPixellate") else { return nil }
            filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(max(4, strength), forKey: kCIInputScaleKey)
            // Blocks start at the rect's top-left corner (Core Image is y-up).
            filter.setValue(CIVector(x: extent.minX, y: extent.maxY), forKey: kCIInputCenterKey)
            guard let pixelated = filter.outputImage else { return nil }
            output = pixelated.cropped(to: extent)
        }
        return BackgroundPainter.sharedCIContext.context.createCGImage(
            output, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
