import AppKit
import ScreenXCore

/// Lupe: 15×15 Pixel des Standbilds um den Zeiger, 8-fach ohne Interpolation,
/// mit Pixelraster, markiertem Mittelpixel und Koordinaten in Pixeln.
final class MagnifierView: NSView {
    static let zoom: CGFloat = 8
    static let pixels = 15
    private static let labelHeight: CGFloat = 20
    private static var side: CGFloat { zoom * CGFloat(pixels) }

    private let image: CGImage?
    private var pixel = CGPoint(x: -1, y: -1)

    init(image: CGImage?) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side + Self.labelHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `pixel` liegt im Bild des Monitors (Ursprung oben links, ganzzahlig).
    func show(pixel: CGPoint) {
        guard pixel != self.pixel else { return }
        self.pixel = pixel
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let side = Self.side
        let zoomRect = CGRect(x: 0, y: Self.labelHeight, width: side, height: side)

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        drawPixels(in: ctx, zoomRect: zoomRect)
        drawGrid(in: ctx, zoomRect: zoomRect)

        let half = CGFloat(Self.pixels / 2) * Self.zoom
        let center = CGRect(x: zoomRect.minX + half, y: zoomRect.minY + half, width: Self.zoom, height: Self.zoom)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(center.insetBy(dx: 0.5, dy: 0.5))

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))

        drawLabel(in: CGRect(x: 0, y: 0, width: side, height: Self.labelHeight))
    }

    private func drawPixels(in ctx: CGContext, zoomRect: CGRect) {
        guard let image else { return }
        let half = CGFloat(Self.pixels / 2)
        let count = CGFloat(Self.pixels)
        let region = CGRect(x: pixel.x - half, y: pixel.y - half, width: count, height: count)
        let clipped = region.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clipped.isNull, let crop = ImageCropper.crop(image, to: clipped) else { return }
        let zoom = Self.zoom
        let dest = CGRect(
            x: zoomRect.minX + (clipped.minX - region.minX) * zoom,
            y: zoomRect.maxY - (clipped.maxY - region.minY) * zoom,
            width: clipped.width * zoom,
            height: clipped.height * zoom
        )
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: dest)
        ctx.restoreGState()
    }

    private func drawGrid(in ctx: CGContext, zoomRect: CGRect) {
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1)
        for i in 1..<Self.pixels {
            let offset = CGFloat(i) * Self.zoom
            ctx.move(to: CGPoint(x: zoomRect.minX + offset, y: zoomRect.minY))
            ctx.addLine(to: CGPoint(x: zoomRect.minX + offset, y: zoomRect.maxY))
            ctx.move(to: CGPoint(x: zoomRect.minX, y: zoomRect.minY + offset))
            ctx.addLine(to: CGPoint(x: zoomRect.maxX, y: zoomRect.minY + offset))
        }
        ctx.strokePath()
    }

    private func drawLabel(in rect: CGRect) {
        let text = "\(Int(pixel.x)), \(Int(pixel.y))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
