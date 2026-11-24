import AppKit

/// Gestrichelter roter Rahmen (2 pt) außen um den Aufnahmebereich, über den ganzen Bildschirm gelegt und
/// klickdurchlässig. Während des Countdowns ist außerhalb des Bereichs leicht abgedunkelt.
/// Als ScreenX-Fenster ist er vom Video ausgeschlossen.
final class RecordingFrameWindow: NSPanel {
    private let frameView: FrameView

    /// `area` in AppKit-Global-Koordinaten, `screenFrame` ist der Bildschirm, der ihn enthält.
    init(area: CGRect, screenFrame: CGRect) {
        frameView = FrameView(frame: NSRect(origin: .zero, size: screenFrame.size))
        frameView.hole = area.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = frameView
        setFrame(screenFrame, display: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var dimsOutside: Bool {
        get { frameView.dims }
        set {
            frameView.dims = newValue
            frameView.needsDisplay = true
        }
    }

    func show() {
        orderFrontRegardless()
    }

    private final class FrameView: NSView {
        var hole: CGRect = .zero
        var dims = false

        override func draw(_ dirtyRect: NSRect) {
            if dims {
                let dim = NSBezierPath(rect: bounds)
                dim.append(NSBezierPath(rect: hole))
                dim.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.18).setFill()
                dim.fill()
            }
            // Außen um den Bereich, damit die Linie keine aufgenommenen Pixel verdeckt.
            let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.setLineDash([6, 4], count: 2, phase: 0)
            RecordingColors.red.setStroke()
            border.stroke()
        }
    }
}

@MainActor
enum RecordingColors {
    /// `#FF3B30`
    static let red = NSColor(srgbRed: 1, green: 59 / 255, blue: 48 / 255, alpha: 1)
}
