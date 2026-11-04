import AppKit
import ScreenXCore

/// Bearbeitet den Text einer Text- bzw. Notiz-Anmerkung direkt auf der Arbeitsfläche: ein `NSTextView`
/// liegt über dem Textbereich (bei Notizen ohne den Innenabstand), skaliert auf die Ansicht, in Schrift
/// und Farbe der Darstellung. Die Vorschau lässt den Text währenddessen weg.
///
/// Zustand und Undo liegen im ViewModel (`beginTextEditing` … `endTextEditing`); `sync` folgt
/// `vm.editingTextID`. ⌘↩ oder ein Klick daneben übernimmt, Esc bricht ab. Tippen hat ein eigenes Undo,
/// das die Historie des Dokuments nicht berührt.
@MainActor
final class InlineTextEditor: NSObject, NSTextViewDelegate {
    private let textView = InlineTextView()
    private let typingUndo = UndoManager()
    private weak var vm: EditorViewModel?
    /// ID der Anmerkung, für die das Textfeld gerade offen ist.
    private(set) var annotationID: UUID?
    /// Unterdrückt Rückmeldungen, während das Feld geschlossen wird.
    private var isClosing = false

    override init() {
        super.init()
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.focusRingType = .none
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.onCommit = { [weak self] in self?.finish(commit: true) }
        textView.onCancel = { [weak self] in self?.finish(commit: false) }
    }

    var isOpen: Bool { annotationID != nil }

    /// Rahmen des Textfelds in der Ansicht (ungedreht), zum Prüfen von Mausposition und Zeiger.
    func contains(_ point: CGPoint) -> Bool {
        isOpen && textView.frame.contains(point)
    }

    /// Öffnet, verschiebt oder schließt das Textfeld passend zu `vm.editingTextID`.
    func sync(in host: NSView, vm: EditorViewModel, mapping: CanvasMapping, viewScale: CGFloat) {
        self.vm = vm
        guard let id = vm.editingTextID else {
            close()
            return
        }
        guard let annotation = vm.model.annotations.first(where: { $0.id == id }),
              let rect = AnnotationTextLayout.textRect(of: annotation),
              let style = AnnotationTextLayout.textStyle(of: annotation, originalScale: vm.captureScale)
        else {
            // Die Anmerkung ist weg: die Bearbeitung abschließen (nach dem laufenden Auffrischen der Ansicht).
            close()
            Task { @MainActor [weak vm] in
                if vm?.editingTextID == id { vm?.endTextEditing(commit: true) }
            }
            return
        }
        let isOpening = annotationID != id
        if isOpening {
            close()
            annotationID = id
            textView.string = Self.text(of: annotation)
            typingUndo.removeAllActions()
            host.addSubview(textView)
        }
        layout(rect: rect, rotation: annotation.rotation, style: style, mapping: mapping, viewScale: viewScale)
        if isOpening {
            host.window?.makeFirstResponder(textView)
            textView.selectedRange = NSRange(location: (textView.string as NSString).length, length: 0)
        }
    }

    /// Schließt das Textfeld ohne Rückmeldung an das ViewModel.
    func close() {
        guard annotationID != nil else { return }
        isClosing = true
        defer { isClosing = false }
        annotationID = nil
        if let window = textView.window, window.firstResponder === textView {
            window.makeFirstResponder(textView.superview)
        }
        textView.removeFromSuperview()
    }

    private func layout(rect: CGRect, rotation: Double, style: AnnotationTextLayout.TextStyle,
                        mapping: CanvasMapping, viewScale: CGFloat) {
        let origin = mapping.toView(rect.origin)
        let frame = CGRect(x: origin.x, y: origin.y, width: max(rect.width * viewScale, 1),
                           height: max(rect.height * viewScale, 1))
        // Erst ungedreht platzieren, dann um die Mitte drehen (wie die Anmerkung um die Mitte ihres Rahmens;
        // in der gespiegelten Ansicht dreht ein positiver Winkel wie im Bild im Uhrzeigersinn).
        textView.frameCenterRotation = 0
        if textView.frame != frame {
            textView.frame = frame
            textView.textContainer?.containerSize = CGSize(width: frame.width, height: .greatestFiniteMagnitude)
        }
        textView.frameCenterRotation = CGFloat(rotation * 180 / .pi)

        let size = max(style.fontSize * viewScale, 1)
        let font = style.bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        if textView.font != font { textView.font = font }
        let color = NSColor(cgColor: style.color.cgColor) ?? .textColor
        if textView.textColor != color {
            textView.textColor = color
            textView.insertionPointColor = color
        }
        textView.typingAttributes = [.font: font, .foregroundColor: color]
    }

    private func finish(commit: Bool) {
        guard !isClosing, let id = annotationID, let vm, vm.editingTextID == id else { return }
        vm.endTextEditing(commit: commit)
        close()
    }

    private static func text(of a: Annotation) -> String {
        switch a.kind {
        case let .text(_, string, _, _, _), let .note(_, string, _): string
        default: ""
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isClosing, annotationID != nil else { return }
        vm?.updateEditingText(textView.string)
    }

    /// Fokus verloren (z. B. Klick in den Inspektor): übernehmen. Erst nach dem Wechsel des Fokus,
    /// damit das Feld nicht mitten darin entfernt wird.
    func textDidEndEditing(_ notification: Notification) {
        guard !isClosing, annotationID != nil else { return }
        Task { @MainActor [weak self] in self?.finish(commit: true) }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        typingUndo
    }
}

/// Textfeld mit ⌘↩ (übernehmen) und Esc (abbrechen); ↩ allein beginnt eine neue Zeile.
final class InlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private static let returnKeys: Set<UInt16> = [36, 76]
    private static let escapeKey: UInt16 = 53

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if Self.returnKeys.contains(event.keyCode), flags == .command {
            onCommit?()
        } else if event.keyCode == Self.escapeKey, flags.isEmpty {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if window?.firstResponder === self, Self.returnKeys.contains(event.keyCode), flags == .command {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
