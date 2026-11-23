import AppKit
import QuartzCore

/// Zeigt bei jedem Mausklick einen Kreis (36 pt, `#FF3B30` mit 35 % Deckkraft, 0,4 s Ausblenden).
/// Ein klickdurchlässiges Fenster pro Bildschirm. Diese Fenster sind die einzigen ScreenX-Fenster im Video:
/// ihre IDs gehen als `includedWindowIDs` an die Engine, deshalb müssen sie vor dem Start sichtbar sein.
@MainActor
final class ClickHighlighter {
    private static let diameter: CGFloat = 36
    private static let fadeDuration: CFTimeInterval = 0.4

    private var windows: [NSWindow] = []
    private var monitor: Any?

    /// IDs der Kreis-Fenster (für den Filter der Aufnahme).
    var windowIDs: [CGWindowID] {
        windows.map { CGWindowID($0.windowNumber) }
    }

    func start() {
        stop()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            self?.showCircle(at: NSEvent.mouseLocation)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
    }

    /// `point` in AppKit-Global-Koordinaten.
    private func showCircle(at point: CGPoint) {
        guard let window = windows.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let layer = window.contentView?.layer else { return }
        let local = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        let size = Self.diameter
        let circle = CAShapeLayer()
        circle.frame = CGRect(x: local.x - size / 2, y: local.y - size / 2, width: size, height: size)
        circle.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
        circle.fillColor = RecordingColors.red.withAlphaComponent(0.35).cgColor
        layer.addSublayer(circle)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.fadeDuration
        circle.opacity = 0
        circle.add(fade, forKey: "fade")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.fadeDuration + 0.05))
            circle.removeFromSuperlayer()
        }
    }
}
