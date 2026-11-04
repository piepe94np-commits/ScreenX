import AppKit
import ScreenXCore
import SwiftUI

/// Legt die Interaktionsschicht exakt über die Vorschau der Arbeitsfläche.
/// `annotations`, `selection`, `tool`, `editingTextID` und `cropDraft` sind nur Eingaben, damit SwiftUI die
/// Schicht bei jeder Änderung auffrischt; die Ansicht liest den aktuellen Stand selbst aus dem ViewModel.
struct AnnotationInteraction: NSViewRepresentable {
    let vm: EditorViewModel
    let mapping: CanvasMapping
    /// Ansichtspunkte je Pixel der Arbeitsfläche.
    let viewScale: CGFloat
    let annotations: [Annotation]
    let selection: Set<UUID>
    let tool: EditorTool
    let editingTextID: UUID?
    let cropDraft: CGRect?

    func makeNSView(context: Context) -> AnnotationInteractionView {
        AnnotationInteractionView(vm: vm, mapping: mapping, viewScale: viewScale)
    }

    func updateNSView(_ view: AnnotationInteractionView, context: Context) {
        view.vm = vm
        view.mapping = mapping
        view.viewScale = viewScale
        view.syncTextEditor()
        view.needsDisplay = true
        view.refreshCursor()
    }

    /// Entfernt den Tastenmonitor sofort, auch wenn die Ansicht ohne `viewWillMove(toWindow: nil)` verschwindet.
    static func dismantleNSView(_ view: AnnotationInteractionView, coordinator: ()) {
        view.removeKeyMonitor()
    }
}

/// Maus und Tasten auf der Arbeitsfläche: Anmerkungen zeichnen, auswählen, verschieben, skalieren, drehen,
/// Text bearbeiten (`InlineTextEditor`, Doppelklick) und zuschneiden (`CropInteraction`).
/// Koordinaten der Ansicht: Punkte mit Ursprung oben links, die Arbeitsfläche beginnt bei (0, 0).
/// Jeder Zug ist genau ein Undo-Schritt (`DragOperation`).
final class AnnotationInteractionView: NSView {
    /// Treffer-Toleranz in Ansichtspunkten, unabhängig vom Zoom.
    private static let hitTolerance: CGFloat = 8

    var vm: EditorViewModel {
        didSet { if vm !== oldValue { connect() } }
    }
    var mapping: CanvasMapping
    var viewScale: CGFloat
    private var operation: DragOperation?
    private var cropDrag: CropInteraction.Drag?
    private let textEditor = InlineTextEditor()
    private var keyMonitor: KeyMonitor?

    init(vm: EditorViewModel, mapping: CanvasMapping, viewScale: CGFloat) {
        self.vm = vm
        self.mapping = mapping
        self.viewScale = viewScale
        super.init(frame: .zero)
        connect()
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Undo/Redo brechen einen laufenden Zug zuerst ab, damit er die Historie nicht verfälscht.
    private func connect() {
        vm.interruptInteraction = { [weak self] in self?.interrupt() }
    }

    private func interrupt() {
        if let operation {
            operation.cancel(vm: vm)
            self.operation = nil
        }
        if let cropDrag {
            vm.cropDraft = cropDrag.startRect
            self.cropDrag = nil
        }
        needsDisplay = true
    }

    /// Öffnet bzw. schließt das Textfeld passend zu `vm.editingTextID`.
    func syncTextEditor() {
        textEditor.sync(in: self, vm: vm, mapping: mapping, viewScale: viewScale)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Tasten

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, keyMonitor == nil {
            keyMonitor = KeyMonitor { [weak self] event in self?.handleKey(event) }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { removeKeyMonitor() }
    }

    func removeKeyMonitor() {
        keyMonitor?.remove()
        keyMonitor = nil
    }

    /// ⌫/Entf, ⌘D, ⌘], ⌘[, Esc und Pfeiltasten (⇧: 10 px) in diesem Fenster, solange kein Text bearbeitet wird
    /// und kein Blatt offen ist. Buchstaben ohne Modifier (Werkzeuge) behandelt das Editor-Fenster.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
              !(window.firstResponder is NSText)
        else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])

        if vm.tool == .crop {
            if event.keyCode == KeyCode.escape, flags.isEmpty {
                if cropDrag != nil { interrupt() } else { vm.discardCrop() }
                return true
            }
            if KeyCode.returnKeys.contains(event.keyCode), flags.isEmpty, cropDrag == nil {
                vm.commitCrop()
                return true
            }
            return false
        }

        if event.keyCode == KeyCode.escape, flags.isEmpty {
            if let operation {
                operation.cancel(vm: vm)
                self.operation = nil
            } else if !vm.selection.isEmpty {
                vm.select(nil, extend: false)
            } else if vm.tool != .select {
                vm.tool = .select
            } else {
                return false
            }
            needsDisplay = true
            return true
        }
        // Während eines Zugs ändern Tasten nichts am Modell.
        guard operation == nil, !vm.selection.isEmpty, !vm.isReadOnly else { return false }

        if [KeyCode.delete, KeyCode.forwardDelete].contains(event.keyCode), flags.isEmpty {
            vm.deleteSelection()
            return true
        }
        if let direction = KeyCode.arrowDirections[event.keyCode], flags.subtracting(.shift).isEmpty {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let delta = CGVector(dx: direction.dx * step, dy: direction.dy * step)
            vm.applyToSelection(String(localized: "Bewegen")) { $0 = AnnotationGeometry.moved($0, by: delta) }
            return true
        }

        // ⌘[ und ⌘] auch auf Tastaturen, auf denen die Klammern ⌥ brauchen (z. B. deutsch: ⌥5 / ⌥6).
        guard flags.contains(.command), !flags.contains(.control) else { return false }
        let typed = [event.characters, event.charactersIgnoringModifiers].compactMap { $0 }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
            vm.duplicateSelection()
            return true
        }
        if typed.contains("]") {
            vm.bringForward()
            return true
        }
        if typed.contains("[") {
            vm.sendBackward()
            return true
        }
        return false
    }

    // MARK: - Maus

    private func viewPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// Griff der einzigen ausgewählten (sichtbaren) Anmerkung unter `point` (Ansichtspunkte).
    private func handleHit(at point: CGPoint) -> (Handle, Annotation)? {
        guard vm.selection.count == 1,
              let target = vm.interactiveAnnotations.first(where: { vm.selection.contains($0.id) }),
              let handle = SelectionOverlayLayer.handle(at: point, of: target, mapping: mapping)
        else { return nil }
        return (handle, target)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Ein Klick neben das Textfeld übernimmt den Text (und tut sonst nichts).
        if vm.editingTextID != nil {
            vm.endTextEditing(commit: true)
            syncTextEditor()
            needsDisplay = true
            return
        }
        guard operation == nil, cropDrag == nil else { return }
        let inView = viewPoint(event)
        let p = mapping.toOriginal(inView)
        let shift = event.modifierFlags.contains(.shift)

        if vm.tool == .crop {
            cropMouseDown(at: p, inView: inView, clickCount: event.clickCount)
            return
        }

        if !vm.isReadOnly, let hit = handleHit(at: inView) {
            let (handle, target) = hit
            let kind: DragOperation.Kind = handle == .rotate ? .rotate(target) : .resize(handle, target)
            operation = DragOperation(kind, at: p, inView: inView, vm: vm)
            refreshCursor(at: inView)
            return
        }

        // Doppelklick (Auswahl) bzw. Klick mit dem Text- oder Notizwerkzeug auf einen Text oder eine Notiz:
        // bearbeiten.
        let editsText = (vm.tool == .select && event.clickCount == 2) || vm.tool == .text || vm.tool == .note
        if !vm.isReadOnly, editsText, let id = textAnnotation(at: p) {
            vm.beginTextEditing(id, isNew: false)
            syncTextEditor()
            needsDisplay = true
            return
        }

        switch vm.tool {
        case .select:
            let tolerance = Self.hitTolerance / max(viewScale, 0.0001)
            // Nur sichtbare Anmerkungen: was der Zuschnitt ganz verdeckt, lässt sich nicht treffen.
            if let hit = AnnotationGeometry.hitTest(p, in: vm.interactiveAnnotations, tolerance: tolerance) {
                if shift {
                    vm.select(hit, extend: true)
                } else {
                    if !vm.selection.contains(hit) { vm.select(hit, extend: false) }
                    let ids = vm.selection
                    let originals = Dictionary(uniqueKeysWithValues: vm.model.annotations
                        .filter { ids.contains($0.id) }.map { ($0.id, $0) })
                    operation = DragOperation(.move(originals), at: p, inView: inView, vm: vm)
                }
            } else {
                vm.select(nil, extend: shift)
                operation = DragOperation(.marquee(base: vm.selection), at: p, inView: inView, vm: vm)
            }
        case .counter:
            guard !vm.isReadOnly else { return }
            vm.select(nil, extend: false)
            let counter = DragOperation.makeCounter(at: p, in: vm.model.annotations)
            operation = DragOperation(.counter(counter), at: p, inView: inView, vm: vm)
        case .crop:
            return
        default:
            guard !vm.isReadOnly else { return }
            vm.select(nil, extend: false)
            operation = DragOperation(.draw(vm.tool, id: UUID()), at: p, inView: inView, vm: vm)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inView = viewPoint(event)
        if let cropDrag {
            vm.cropDraft = cropDrag.rect(to: mapping.toOriginal(inView), shift: event.modifierFlags.contains(.shift),
                                         bounds: vm.originalBounds)
            needsDisplay = true
            return
        }
        guard operation != nil else { return }
        operation?.update(to: mapping.toOriginal(inView), inView: inView,
                          shift: event.modifierFlags.contains(.shift), vm: vm)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inView = viewPoint(event)
        if cropDrag != nil {
            cropDrag = nil
            needsDisplay = true
            refreshCursor(at: inView)
            return
        }
        guard let operation else { return }
        self.operation = nil
        operation.finish(at: mapping.toOriginal(inView), inView: inView, vm: vm)
        syncTextEditor()
        needsDisplay = true
        refreshCursor(at: inView)
    }

    /// Oberste sichtbare Text- bzw. Notiz-Anmerkung unter `p` (Pixel des Originals).
    private func textAnnotation(at p: CGPoint) -> UUID? {
        let tolerance = Self.hitTolerance / max(viewScale, 0.0001)
        let candidates = vm.interactiveAnnotations
        guard let id = AnnotationGeometry.hitTest(p, in: candidates, tolerance: tolerance),
              let annotation = candidates.first(where: { $0.id == id }),
              AnnotationTextLayout.textRect(of: annotation) != nil
        else { return nil }
        return id
    }

    /// Zuschnitt: Griff, Rahmen verschieben oder neuen Rahmen aufziehen; Doppelklick in den Rahmen übernimmt.
    private func cropMouseDown(at p: CGPoint, inView: CGPoint, clickCount: Int) {
        guard !vm.isReadOnly, let draft = vm.cropDraft else { return }
        let part = CropInteraction.part(at: inView, draft: draft, mapping: mapping)
        if clickCount == 2, part == .move {
            vm.commitCrop()
            return
        }
        cropDrag = CropInteraction.Drag(part: part, startRect: draft, start: p)
        refreshCursor(at: inView)
    }

    // MARK: - Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        if vm.tool == .crop {
            guard let draft = vm.cropDraft else { return }
            let layout = vm.displayLayout
            let rect = layout.imageRect
            let radius = max(0, min(CGFloat(vm.model.style.cornerRadius), min(rect.width, rect.height) / 2))
            CropInteraction.draw(draft: draft, bounds: vm.originalBounds, mapping: mapping,
                                 imageCornerRadius: radius * viewScale)
            return
        }
        // Die gerade bearbeitete Anmerkung zeigt statt der Auswahl ihr Textfeld.
        let selected = vm.model.annotations.filter { vm.selection.contains($0.id) && $0.id != vm.editingTextID }
        guard !selected.isEmpty || operation?.marqueeRectInView != nil else { return }
        SelectionOverlayLayer(selected: selected, mapping: mapping, marquee: operation?.marqueeRectInView).draw()
    }

    // MARK: - Mauszeiger

    override func cursorUpdate(with event: NSEvent) {
        refreshCursor(at: viewPoint(event))
    }

    override func mouseMoved(with event: NSEvent) {
        refreshCursor(at: viewPoint(event))
    }

    /// Setzt den Mauszeiger, wenn die Maus über der Ansicht steht (z. B. nach einem Werkzeugwechsel).
    func refreshCursor() {
        guard let window, window.isKeyWindow else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        refreshCursor(at: point)
    }

    private func refreshCursor(at point: CGPoint) {
        cursor(at: point).set()
    }

    /// Größenänderung über Griffen, Fadenkreuz bei Zeichenwerkzeugen, sonst Pfeil.
    private func cursor(at point: CGPoint) -> NSCursor {
        if vm.tool == .crop {
            if let cropDrag { return CropInteraction.cursor(for: cropDrag.part, dragging: true) }
            guard let draft = vm.cropDraft, !vm.isReadOnly else { return .arrow }
            return CropInteraction.cursor(for: CropInteraction.part(at: point, draft: draft, mapping: mapping),
                                          dragging: false)
        }
        if textEditor.contains(point) { return .iBeam }
        if case .rotate = operation?.kind { return .closedHand }
        if !vm.isReadOnly, let hit = handleHit(at: point) {
            let (handle, target) = hit
            switch handle {
            case .rotate:
                return .openHand
            case .start, .end, .control:
                return .crosshair
            default:
                let center = mapping.toView(AnnotationGeometry.pivot(of: target))
                let handlePoint = SelectionOverlayLayer.handles(for: target, mapping: mapping)
                    .first { $0.handle == handle }?.point ?? point
                return Self.resizeCursor(angle: atan2(handlePoint.y - center.y, handlePoint.x - center.x))
            }
        }
        switch vm.tool {
        case .select: return .arrow
        default: return .crosshair
        }
    }

    /// Größenänderungs-Zeiger in Richtung des Griffs (Winkel in der gespiegelten Ansicht, 0 = rechts),
    /// auf 45° gerundet, damit gedrehte Anmerkungen den passenden Zeiger erhalten.
    private static func resizeCursor(angle: CGFloat) -> NSCursor {
        let positions: [NSCursor.FrameResizePosition] = [
            .right, .bottomRight, .bottom, .bottomLeft, .left, .topLeft, .top, .topRight,
        ]
        let index = Int((angle / (.pi / 4)).rounded())
        return NSCursor.frameResize(position: positions[((index % 8) + 8) % 8], directions: .all)
    }
}

/// Tastencodes (unabhängig von der Tastaturbelegung).
private enum KeyCode {
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let escape: UInt16 = 53
    /// ↩ und ↩ auf dem Ziffernblock.
    static let returnKeys: Set<UInt16> = [36, 76]
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126

    /// Richtung je Pfeiltaste in Ansichtskoordinaten (y nach unten).
    static let arrowDirections: [UInt16: CGVector] = [
        left: CGVector(dx: -1, dy: 0), right: CGVector(dx: 1, dy: 0),
        up: CGVector(dx: 0, dy: -1), down: CGVector(dx: 0, dy: 1),
    ]
}

/// Lokaler keyDown-Monitor. Er entfernt sich selbst, falls die Ansicht ohne `viewWillMove(toWindow: nil)`
/// verschwindet (z. B. wenn das Fenster samt Ansichten freigegeben wird): beim ersten Ereignis danach bzw.
/// spätestens, wenn er selbst freigegeben wird.
@MainActor
private final class KeyMonitor {
    private var token: Any?

    /// `handle` gibt `true` zurück, wenn es das Ereignis verbraucht hat; `nil` heißt: Ansicht ist weg.
    init(_ handle: @escaping @MainActor (NSEvent) -> Bool?) {
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let consumed = handle(event) else {
                self?.remove()
                return event
            }
            return consumed ? nil : event
        }
    }

    isolated deinit {
        remove()
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
