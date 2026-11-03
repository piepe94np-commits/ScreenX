import AppKit
import OSLog
import ScreenXCore

/// Steuert die Auswahl-Overlays für Bereich und Fenster. `nil` als Ergebnis bedeutet Abbruch,
/// ein geworfener Fehler einen echten Fehlschlag.
/// Die Continuation wird genau einmal fortgesetzt, die Overlays sind danach geschlossen.
@MainActor
final class OverlayController {
    private static let logger = Logger(subsystem: "com.screenx.app", category: "overlay")

    private let service: CaptureService
    private var isRunning = false
    private var continuation: CheckedContinuation<Capture?, any Error>?
    private var windows: [OverlayWindow] = []

    // Bereichsmodus
    private var areaViews: [AreaSelectionView] = []
    private var frozen: [UInt32: CGImage] = [:]
    private var drag: AreaDrag?
    private var pointer = CGPoint.zero

    // Fenstermodus
    private var highlightViews: [WindowHighlightView] = []
    private var candidates: [WindowInfo] = []
    private var hovered: WindowInfo?
    private var shadow = false

    init(service: CaptureService) {
        self.service = service
    }

    // MARK: - Bereich

    func selectArea() async throws -> Capture? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        let displays = try await freezeDisplays()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            for display in displays {
                let view = AreaSelectionView(display: display, image: frozen[display.id])
                view.onEvent = { [weak self] event, display in self?.handleArea(event, on: display) }
                areaViews.append(view)
                present(view, on: display, backdrop: frozen[display.id])
            }
            focusPanel()
            pointer = NSEvent.mouseLocation
            refreshArea()
        }
    }

    /// Friert alle Monitore parallel ein, bevor ein Overlay erscheint.
    private func freezeDisplays() async throws -> [DisplayInfo] {
        do {
            let displays = try await service.displays()
            guard !displays.isEmpty else { throw CaptureError.displayNotFound }
            let service = self.service
            frozen = try await withThrowingTaskGroup(of: (UInt32, CGImage).self) { group in
                for display in displays {
                    let id = display.id
                    group.addTask { (id, try await service.captureDisplay(id)) }
                }
                var images: [UInt32: CGImage] = [:]
                for try await (id, image) in group { images[id] = image }
                return images
            }
            return displays
        } catch {
            frozen = [:]
            Self.logger.error("Einfrieren fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func handleArea(_ event: OverlayEvent, on display: DisplayInfo) {
        switch event {
        case .cancel:
            finish(nil)
            return
        case .moved(let point):
            pointer = point
        case .down(let point):
            pointer = point
            drag = AreaDrag(display: display, anchor: point, last: point)
            drag?.resize()
        case .dragged(let point, let shift):
            pointer = point
            drag?.drag(to: point, shift: shift)
        case .shift(let on):
            drag?.setSquare(on)
        case .space(let down):
            drag?.setMoving(down)
        case .up(let point):
            pointer = point
            guard drag != nil else { return }
            completeArea()
            return
        }
        refreshArea()
    }

    private func refreshArea() {
        for view in areaViews {
            var selection: CGRect?
            if let drag, drag.display.id == view.display.id, !drag.rect.isNull {
                selection = SelectionGeometry.pixelRect(for: drag.rect, on: drag.display)
            }
            view.update(selection: selection, pointer: pointer)
        }
    }

    private func completeArea() {
        guard let drag, let image = frozen[drag.display.id] else { return finish(nil) }
        let rect = SelectionGeometry.clamp(drag.rect, to: drag.display.frame)
        guard SelectionGeometry.isValid(rect),
              let cropped = ImageCropper.crop(image, to: SelectionGeometry.pixelRect(for: rect, on: drag.display))
        else { return finish(nil) }
        finish(Capture(image: cropped, scale: drag.display.scale, mode: .area, date: Date()))
    }

    // MARK: - Fenster

    func selectWindow(shadow: Bool) async throws -> Capture? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        do {
            candidates = try await service.windows()
        } catch {
            Self.logger.error("Fensterliste fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        self.shadow = shadow
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            for display in CaptureService.currentDisplays() {
                let view = WindowHighlightView(display: display)
                view.onEvent = { [weak self] event, _ in self?.handleWindow(event) }
                highlightViews.append(view)
                present(view, on: display, backdrop: nil)
            }
            focusPanel()
            hover(at: NSEvent.mouseLocation)
        }
    }

    private func handleWindow(_ event: OverlayEvent) {
        switch event {
        case .cancel:
            finish(nil)
        case .moved(let point), .dragged(let point, _):
            hover(at: point)
        case .down(let point):
            hover(at: point)
            if let hovered { captureWindow(hovered) }
        case .up, .shift, .space:
            break
        }
    }

    private func hover(at point: CGPoint) {
        let topLeft = CoordinateSpace.toTopLeft(point, primaryHeight: primaryHeight)
        hovered = WindowHitTester.window(
            at: topLeft, in: candidates, excludingPID: ProcessInfo.processInfo.processIdentifier
        )
        let highlight = hovered.map { CoordinateSpace.toBottomLeft($0.frame, primaryHeight: primaryHeight) }
        highlightViews.forEach { $0.update(highlight: highlight) }
    }

    private func captureWindow(_ target: WindowInfo) {
        let scale = backingScale(for: target)
        let shadow = shadow
        closeWindows()
        Task {
            // Kurz (50 ms) warten, bis der Window Server die ausgeblendeten Overlays nicht mehr zeigt.
            try? await Task.sleep(for: .milliseconds(50))
            do {
                let image = try await service.captureWindow(target.id, shadow: shadow)
                finish(Capture(image: image, scale: scale, mode: .window, date: Date(), windowTitle: target.title))
            } catch {
                Self.logger.error("Fensteraufnahme fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                finish(.failure(error))
            }
        }
    }

    /// Skalierung des Bildschirms, der den größten Teil des Fensters zeigt.
    private func backingScale(for window: WindowInfo) -> CGFloat {
        let frame = CoordinateSpace.toBottomLeft(window.frame, primaryHeight: primaryHeight)
        let screen = NSScreen.screens.max { lhs, rhs in
            area(lhs.frame.intersection(frame)) < area(rhs.frame.intersection(frame))
        }
        return screen?.backingScaleFactor ?? 1
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    // MARK: - Gemeinsam

    /// Höhe des Bildschirms mit Ursprung (0,0).
    private var primaryHeight: CGFloat {
        let screens = NSScreen.screens
        return (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height ?? 0
    }

    private func present(_ view: OverlayInputView, on display: DisplayInfo, backdrop: CGImage?) {
        let window = OverlayWindow(frame: display.frame)
        window.present(view, backdrop: backdrop)
        windows.append(window)
    }

    /// Macht das Panel unter dem Zeiger zum Key-Fenster, ohne die App zu aktivieren.
    /// Bewusst kein `NSApp.activate()`: das würde die vorderste App deaktivieren (Fenster würden
    /// inaktiv aufgenommen) und ScreenX bliebe danach aktiv, sodass Tastatureingaben ins Leere gehen.
    /// `.nonactivatingPanel` mit `canBecomeKey` erhält Esc/Leertaste/⇧ trotzdem (wie Spotlight).
    private func focusPanel() {
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKeyAndOrderFront(nil)
    }

    private func finish(_ capture: Capture?) {
        finish(.success(capture))
    }

    /// Schließt die Overlays und setzt die Continuation genau einmal fort.
    private func finish(_ result: Result<Capture?, any Error>) {
        closeWindows()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func closeWindows() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        // Geschlossene Panels bis zum nächsten Runloop-Durchlauf halten: `finish` läuft oft in
        // deren eigenem keyDown/mouseUp, das noch auf dem Stack liegt.
        let closed = windows
        DispatchQueue.main.async { withExtendedLifetime(closed) {} }
        windows = []
        areaViews = []
        highlightViews = []
        frozen = [:]
        drag = nil
        candidates = []
        hovered = nil
        NSCursor.arrow.set()
    }
}
