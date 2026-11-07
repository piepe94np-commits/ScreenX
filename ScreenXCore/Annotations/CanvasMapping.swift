import CoreGraphics
import Foundation

/// Maps between editor view points and original-image pixels.
///
/// The view has its origin top-left, with the canvas at (0,0). `viewScale` is view points per canvas pixel.
/// Without a device template: original = (view / viewScale - imageRect.origin) + crop.origin.
/// With a (rectangular, untilted) template, the canvas point minus `imageRect.origin` is a device-image point,
/// which `TemplateGeometry.screenToContentTransform` maps to content pixels; plus the crop origin gives
/// original pixels. The mapping is affine; `scale` is view points per original pixel.
public struct CanvasMapping: Sendable {
    private let originalToView: CGAffineTransform
    private let viewToOriginal: CGAffineTransform
    /// View points per original pixel (the mapping scales both axes alike).
    public let scale: CGFloat
    /// Part of the original shown on the canvas (original pixels): the content, with a template only the
    /// part of it that lies in the screen (`.fill` crops).
    public let visibleRect: CGRect

    public init(layout: CanvasLayout, crop: CGRect?, viewScale: CGFloat) {
        let origin = crop?.origin ?? .zero
        let visible = crop ?? CGRect(origin: .zero, size: layout.imageRect.size)
        self.init(originalToCanvas: CGAffineTransform(translationX: layout.imageRect.minX - origin.x,
                                                      y: layout.imageRect.minY - origin.y),
                  canvasToOriginal: CGAffineTransform(translationX: origin.x - layout.imageRect.minX,
                                                      y: origin.y - layout.imageRect.minY),
                  viewScale: viewScale, visibleRect: visible)
    }

    /// The mapping for the canvas `Renderer.render(input)` draws (layout from `Renderer.layout(for:)`).
    /// `nil` when annotations cannot be edited there (`TemplateGeometry.isAffineEditable` is false), or for a
    /// non-positive `viewScale`.
    public init?(input: RenderInput, viewScale: CGFloat) {
        guard viewScale > 0, viewScale.isFinite,
              TemplateGeometry.isAffineEditable(template: input.template, tilt: input.style.tilt) else { return nil }
        let (canvas, device) = Renderer.layout(for: input)
        let content = Renderer.contentRect(for: input)
        let origin = canvas.imageRect.origin
        guard let template = input.template else {
            self.init(originalToCanvas: CGAffineTransform(translationX: origin.x - content.minX,
                                                          y: origin.y - content.minY),
                      canvasToOriginal: CGAffineTransform(translationX: content.minX - origin.x,
                                                          y: content.minY - origin.y),
                      viewScale: viewScale, visibleRect: content)
            return
        }
        let placement = input.placement ?? TemplatePlacement(templateID: template.id)
        guard let device,
              let toContent = TemplateGeometry.screenToContentTransform(
                template: template, placement: placement, contentSize: content.size,
                frameScale: device.frameScale)
        else { return nil }
        // canvas → device image → content → original
        let canvasToOriginal = CGAffineTransform(translationX: -origin.x, y: -origin.y)
            .concatenating(toContent)
            .concatenating(CGAffineTransform(translationX: content.minX, y: content.minY))
        let source = TemplateGeometry.sourceRect(contentSize: content.size, screenSize: template.screenBounds.size,
                                                 fit: placement.fit, offset: placement.offset).source
        self.init(originalToCanvas: canvasToOriginal.inverted(), canvasToOriginal: canvasToOriginal,
                  viewScale: viewScale,
                  visibleRect: source.offsetBy(dx: content.minX, dy: content.minY).intersection(content))
    }

    private init(originalToCanvas: CGAffineTransform, canvasToOriginal: CGAffineTransform, viewScale: CGFloat,
                 visibleRect: CGRect) {
        originalToView = originalToCanvas.concatenating(CGAffineTransform(scaleX: viewScale, y: viewScale))
        viewToOriginal = CGAffineTransform(scaleX: 1 / viewScale, y: 1 / viewScale).concatenating(canvasToOriginal)
        let t = originalToView
        scale = sqrt(abs(t.a * t.d - t.b * t.c))
        self.visibleRect = visibleRect
    }

    public func toOriginal(_ viewPoint: CGPoint) -> CGPoint {
        viewPoint.applying(viewToOriginal)
    }

    public func toView(_ originalPoint: CGPoint) -> CGPoint {
        originalPoint.applying(originalToView)
    }
}
