import AppKit

/// Countdown 3-2-1 in der Mitte des Aufnahmeziels: halbtransparenter Kreis (140 pt) mit der Zahl,
/// darunter „Esc bricht ab“. Nicht aktivierend, wird aber Key, damit Esc ankommt.
@MainActor
final class CountdownWindow {
    private static let circleSize: CGFloat = 140
    private static let hintHeight: CGFloat = 24

    private let panel: CountdownPanel
    private let number = NSTextField(labelWithString: "")
    private var task: Task<Void, any Error>?

    /// `center` in AppKit-Global-Koordinaten.
    init(center: CGPoint) {
        let size = CGSize(width: 200, height: Self.circleSize + Self.hintHeight + 12)
        let frame = CGRect(x: center.x - size.width / 2, y: center.y - Self.circleSize / 2 - Self.hintHeight - 12,
                           width: size.width, height: size.height)
        panel = CountdownPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let circle = NSView(frame: NSRect(x: (size.width - Self.circleSize) / 2, y: Self.hintHeight + 12,
                                          width: Self.circleSize, height: Self.circleSize))
        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        circle.layer?.cornerRadius = Self.circleSize / 2
        content.addSubview(circle)

        number.font = .systemFont(ofSize: 72, weight: .bold)
        number.textColor = .white
        number.alignment = .center
        number.frame = NSRect(x: 0, y: (Self.circleSize - 88) / 2, width: Self.circleSize, height: 88)
        circle.addSubview(number)

        let hint = NSTextField(labelWithString: String(localized: "Esc bricht ab"))
        hint.font = .systemFont(ofSize: 13, weight: .semibold)
        hint.textColor = NSColor(srgbRed: 0x3a / 255, green: 0x3a / 255, blue: 0x3c / 255, alpha: 1)
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 0, width: size.width, height: Self.hintHeight)
        content.addSubview(hint)

        panel.contentView = content
        panel.onEscape = { [weak self] in self?.cancel() }
    }

    /// Zählt von `seconds` herunter. `true`, wenn der Countdown durchlief, `false` bei Abbruch.
    func run(seconds: Int) async -> Bool {
        panel.makeKeyAndOrderFront(nil)
        let task = Task { @MainActor [number] in
            for value in stride(from: seconds, to: 0, by: -1) {
                number.stringValue = "\(value)"
                try await Task.sleep(for: .seconds(1))
            }
        }
        self.task = task
        let finished: Bool
        do {
            try await task.value
            finished = true
        } catch {
            finished = false
        }
        close()
        return finished
    }

    func cancel() {
        task?.cancel()
    }

    private func close() {
        task = nil
        panel.orderOut(nil)
        panel.close()
    }
}

private final class CountdownPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
}
