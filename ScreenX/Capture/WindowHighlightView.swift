import AppKit
import ScreenXCore

/// Transparente Fensterauswahl auf einem Bildschirm: hebt das Fenster unter dem Zeiger
/// mit 4 pt blauem Rahmen und leichter Füllung hervor.
final class WindowHighlightView: OverlayInputView {
    private static let borderWidth: CGFloat = 4

    /// Hervorgehobenes Fenster in AppKit-Global-Koordinaten.
    private var highlight: CGRect?

    init(display: DisplayInfo) {
        super.init(display: display, cursor: .arrow)
    }

    func update(highlight newHighlight: CGRect?) {
        guard newHighlight != highlight else { return }
        highlight = newHighlight
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fast unsichtbare Füllung, damit Klicks sicher beim Overlay landen.
        NSColor.black.withAlphaComponent(0.001).setFill()
        bounds.fill()

        guard let highlight else { return }
        let local = highlight.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        guard local.intersects(bounds) else { return }
        NSColor.systemBlue.withAlphaComponent(0.15).setFill()
        local.fill(using: .sourceOver)
        let border = NSBezierPath(rect: local.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2))
        border.lineWidth = Self.borderWidth
        NSColor.systemBlue.setStroke()
        border.stroke()
    }
}
