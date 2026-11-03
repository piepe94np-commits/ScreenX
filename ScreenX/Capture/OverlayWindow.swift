import AppKit
import ScreenXCore

/// Randloses Panel über einem ganzen Bildschirm. Kann Key werden, damit Esc/Leertaste ankommen.
final class OverlayWindow: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        setFrame(frame, display: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Zeigt `content` vollflächig, optional über einem eingefrorenen Standbild.
    func present(_ content: NSView, backdrop: CGImage?) {
        let container = BackdropView(frame: NSRect(origin: .zero, size: frame.size), image: backdrop)
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        contentView = container
        makeFirstResponder(content)
        orderFrontRegardless()
    }
}

/// Zeigt das Standbild als Layer-Inhalt (ohne Neuzeichnen beim Ziehen).
private final class BackdropView: NSView {
    private let image: CGImage?

    init(frame: NSRect, image: CGImage?) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
    }
}

/// Eingaben aus einem Overlay. Punkte liegen in AppKit-Global-Koordinaten.
enum OverlayEvent {
    case moved(CGPoint)
    case down(CGPoint)
    case dragged(CGPoint, shift: Bool)
    case up(CGPoint)
    case shift(Bool)
    case space(Bool)
    case cancel
}

/// Gemeinsame Ereignisbehandlung für die Overlay-Ansichten eines Bildschirms.
class OverlayInputView: NSView {
    private static let escapeKeyCode: UInt16 = 53
    private static let spaceKeyCode: UInt16 = 49

    let display: DisplayInfo
    final var onEvent: ((OverlayEvent, DisplayInfo) -> Void)?
    private let cursor: NSCursor

    init(display: DisplayInfo, cursor: NSCursor) {
        self.display = display
        self.cursor = cursor
        super.init(frame: NSRect(origin: .zero, size: display.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func mouseMoved(with event: NSEvent) {
        cursor.set()
        send(.moved(globalPoint(event)))
    }

    override func mouseDown(with event: NSEvent) { send(.down(globalPoint(event))) }

    override func mouseDragged(with event: NSEvent) {
        send(.dragged(globalPoint(event), shift: event.modifierFlags.contains(.shift)))
    }

    override func mouseUp(with event: NSEvent) { send(.up(globalPoint(event))) }

    override func flagsChanged(with event: NSEvent) {
        send(.shift(event.modifierFlags.contains(.shift)))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Self.escapeKeyCode: send(.cancel)
        case Self.spaceKeyCode where !event.isARepeat: send(.space(true))
        default: break
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == Self.spaceKeyCode { send(.space(false)) }
    }

    /// Lokales Rechteck (Punkte, unten links) für ein Pixelrechteck im Bild dieses Monitors (oben links).
    func localRect(forPixels px: CGRect) -> CGRect {
        let scale = display.scale
        return CGRect(
            x: px.minX / scale,
            y: display.frame.height - px.maxY / scale,
            width: px.width / scale,
            height: px.height / scale
        )
    }

    private func send(_ event: OverlayEvent) { onEvent?(event, display) }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        guard let window = event.window ?? window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}
