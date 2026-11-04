import AppKit
import OSLog
import ScreenXCore

/// Zeigt nach jeder Aufnahme eine schwebende Vorschau-Karte unten links (Schnellzugriff).
/// Karten stapeln sich nach oben (neueste unten), höchstens `maxCards`.
/// Die Panels aktivieren ScreenX nie, damit das vorderste Programm den Fokus behält.
@MainActor
final class QuickAccessController {
    private static let logger = Logger(subsystem: "com.screenx.app", category: "quickAccess")
    private static let maxCards = 5
    private static let edgeInset: CGFloat = 16
    private static let spacing: CGFloat = 12
    private static let animationDuration: TimeInterval = 0.2
    private static let slideDistance: CGFloat = 24
    private static let feedbackDuration: Duration = .seconds(1)

    /// In M1 `nil`: dann gibt es keinen „Bearbeiten“-Button und ein Klick aufs Bild tut nichts.
    var onEdit: ((Capture) -> Void)?

    private let settings: () -> AppSettings
    /// Index 0 ist die neueste Karte (unterste Position).
    private var cards: [QuickAccessCard] = []
    private var visibleFrame: CGRect = .zero

    init(settings: @escaping () -> AppSettings) {
        self.settings = settings
    }

    func show(_ capture: Capture) {
        guard let screen = Self.screenUnderMouse() else {
            Self.logger.error("Kein Bildschirm für den Schnellzugriff gefunden")
            return
        }
        visibleFrame = screen.visibleFrame
        let card = makeCard(for: capture)
        cards.insert(card, at: 0)
        while cards.count > Self.maxCards, let oldest = cards.last {
            close(oldest)
        }
        layout(skipping: card)
        present(card)
        restartTimer(card)
    }

    // MARK: - Karten

    private func makeCard(for capture: Capture) -> QuickAccessCard {
        let model = QuickAccessItemModel(capture: capture)
        let panel = QuickAccessPanel(size: QuickAccessMetrics.panelSize)
        let card = QuickAccessCard(model: model, panel: panel)
        let actions = QuickAccessActions(
            copy: bind(card) { $0.copy($1) },
            save: bind(card) { $0.save($1) },
            edit: onEdit == nil ? nil : bind(card) { $0.edit($1) },
            close: bind(card) { $0.close($1) },
            togglePin: bind(card) { $0.togglePin($1) },
            makeDragFile: { [weak self, weak card] in
                guard let self, let card else { throw CancellationError() }
                return try self.dragFile(for: card)
            },
            dragEnded: { [weak self, weak card] dropped in
                guard let self, let card else { return }
                if dropped {
                    self.close(card)
                } else {
                    // Während des Ziehens kommt kein mouseExited an: Hover neu bestimmen.
                    card.model.isHovered = self.isMouseOver(card)
                    self.restartTimer(card)
                }
            }
        )
        let hosting = QuickAccessHostingView(rootView: QuickAccessItemView(model: model, actions: actions))
        hosting.sizingOptions = []
        hosting.onHover = { [weak self, weak card] hovered in
            guard let self, let card else { return }
            card.model.isHovered = hovered
            self.restartTimer(card)
        }
        panel.contentView = hosting
        return card
    }

    private func bind(
        _ card: QuickAccessCard,
        _ action: @escaping (QuickAccessController, QuickAccessCard) -> Void
    ) -> () -> Void {
        { [weak self, weak card] in
            guard let self, let card else { return }
            action(self, card)
        }
    }

    private func copy(_ card: QuickAccessCard) {
        let capture = card.model.capture
        Clipboard.copy(capture.image, scale: capture.scale)
        showFeedback(.copied, on: card)
    }

    private func save(_ card: QuickAccessCard) {
        let capture = card.model.capture
        let settings = settings()
        do {
            _ = try ImageExporter.write(
                capture.image,
                scale: capture.scale,
                to: settings.saveDirectory,
                date: capture.date,
                format: settings.exportFormat,
                jpegQuality: settings.jpegQuality
            )
            showFeedback(.saved, on: card)
        } catch {
            Self.logger.error("Sichern fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            card.timer?.cancel()
            showSaveError(error)
            restartTimer(card)
        }
    }

    private func edit(_ card: QuickAccessCard) {
        onEdit?(card.model.capture)
        close(card)
    }

    private func isMouseOver(_ card: QuickAccessCard) -> Bool {
        let margins = QuickAccessMetrics.margins
        let frame = card.panel.frame
        let rect = CGRect(
            x: frame.minX + margins.left,
            y: frame.minY + margins.bottom,
            width: QuickAccessMetrics.cardSize.width,
            height: QuickAccessMetrics.cardSize.height
        )
        return NSMouseInRect(NSEvent.mouseLocation, rect, false)
    }

    private func togglePin(_ card: QuickAccessCard) {
        card.model.isPinned.toggle()
        restartTimer(card)
    }

    private func dragFile(for card: QuickAccessCard) throws -> URL {
        // Während des Ziehens darf die Karte nicht automatisch verschwinden.
        card.timer?.cancel()
        if let url = card.dragURL, FileManager.default.fileExists(atPath: url.path) { return url }
        let url = try DragFile.write(card.model.capture, settings: settings(), folder: card.dragFolder)
        card.dragURL = url
        return url
    }

    private func showFeedback(_ feedback: QuickAccessFeedback, on card: QuickAccessCard) {
        card.feedbackTask?.cancel()
        card.model.feedback = feedback
        card.feedbackTask = Task { [weak card] in
            try? await Task.sleep(for: Self.feedbackDuration)
            guard !Task.isCancelled else { return }
            card?.model.feedback = nil
        }
    }

    /// Bewusste Ausnahme von der Nicht-Aktivierung: Der modale Dialog einer LSUIElement-App
    /// läge sonst hinter dem vordersten Programm und wäre nicht erreichbar.
    private func showSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Sichern fehlgeschlagen")
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Timer

    /// Startet die Anzeigedauer neu; überfahrene oder angeheftete Karten schließen nicht automatisch.
    private func restartTimer(_ card: QuickAccessCard) {
        card.timer?.cancel()
        card.timer = nil
        guard !card.model.isPinned, !card.model.isHovered else { return }
        let duration = settings().quickAccessDuration
        card.timer = Task { [weak self, weak card] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, let card else { return }
            self.close(card)
        }
    }

    // MARK: - Anzeige

    private func close(_ card: QuickAccessCard) {
        guard let index = cards.firstIndex(where: { $0 === card }) else { return }
        cards.remove(at: index)
        card.timer?.cancel()
        card.feedbackTask?.cancel()
        try? FileManager.default.removeItem(at: card.dragFolder)
        let panel = card.panel
        let slide = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animate {
            panel.animator().alphaValue = 0
            if slide {
                panel.animator().setFrame(panel.frame.offsetBy(dx: -Self.slideDistance, dy: 0), display: true)
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.animationDuration))
            panel.orderOut(nil)
            panel.close()
        }
        layout(skipping: nil)
    }

    private func present(_ card: QuickAccessCard) {
        let panel = card.panel
        let target = frame(at: 0)
        let slide = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(slide ? target.offsetBy(dx: -Self.slideDistance, dy: 0) : target, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animate {
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// Schiebt alle Karten auf ihre Stapelposition auf dem aktuellen Bildschirm.
    private func layout(skipping skipped: QuickAccessCard?) {
        for (index, card) in cards.enumerated() where card !== skipped {
            let target = frame(at: index)
            guard card.panel.frame != target else { continue }
            animate { card.panel.animator().setFrame(target, display: true) }
        }
    }

    private func frame(at index: Int) -> CGRect {
        let margins = QuickAccessMetrics.margins
        let cardHeight = QuickAccessMetrics.cardSize.height
        let cardX = visibleFrame.minX + Self.edgeInset
        let cardY = visibleFrame.minY + Self.edgeInset + CGFloat(index) * (cardHeight + Self.spacing)
        return CGRect(
            origin: CGPoint(x: cardX - margins.left, y: cardY - margins.bottom),
            size: QuickAccessMetrics.panelSize
        )
    }

    private func animate(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

/// Eine angezeigte Karte mit ihrem Panel und laufenden Aufgaben.
@MainActor
private final class QuickAccessCard {
    let model: QuickAccessItemModel
    let panel: QuickAccessPanel
    var timer: Task<Void, Never>?
    var feedbackTask: Task<Void, Never>?
    var dragURL: URL?
    /// Eigener Unterordner der Karte für die Ziehen-Datei.
    let dragFolder = DragFile.makeFolder()

    init(model: QuickAccessItemModel, panel: QuickAccessPanel) {
        self.model = model
        self.panel = panel
    }
}

/// Randloses, transparentes, nicht aktivierendes Panel; der Schatten wird in SwiftUI gezeichnet.
private final class QuickAccessPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Nie Key: Tastatureingaben bleiben beim vordersten Programm.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
