import CoreGraphics
import Foundation
import ScreenXCore

/// Ein laufender Mauszug auf der Arbeitsfläche, vom Drücken bis zum Loslassen.
/// Änderungen laufen live über `applyLive`; `finish` schließt den Zug als genau einen Undo-Schritt ab,
/// `cancel` (Esc) stellt den Zustand vor dem Zug wieder her. Punkte sind in Pixeln des Originals,
/// `…InView` in Ansichtspunkten.
@MainActor
struct DragOperation {
    enum Kind {
        /// Neue Anmerkung mit einem Zeichenwerkzeug; entsteht erst ab `minimumDrag`.
        case draw(EditorTool, id: UUID)
        /// Zähler: entsteht beim Drücken, Ziehen verschiebt ihn.
        case counter(Annotation)
        /// Verschiebt die Auswahl (Ausgangszustand je ID).
        case move([UUID: Annotation])
        case resize(Handle, Annotation)
        case rotate(Annotation)
        /// Rahmen-Auswahl; `base` ist die Auswahl, die erhalten bleibt (mit ⇧).
        case marquee(base: Set<UUID>)
    }

    /// Kürzere Züge (in Ansichtspunkten) werden verworfen bzw. gelten als Klick.
    static let minimumDrag: CGFloat = 4

    let kind: Kind
    let start: CGPoint
    let startInView: CGPoint
    private(set) var currentInView: CGPoint
    /// Das Modell wurde live geändert (ein Schritt mit `beginContinuousChange` ist offen).
    private(set) var isLive = false

    init(_ kind: Kind, at start: CGPoint, inView startInView: CGPoint, vm: EditorViewModel) {
        self.kind = kind
        self.start = start
        self.startInView = startInView
        currentInView = startInView
        switch kind {
        case let .counter(annotation):
            vm.beginContinuousChange()
            vm.applyLive { $0.annotations.append(annotation) }
            isLive = true
        case .move, .resize, .rotate:
            vm.beginContinuousChange()
            isLive = true
        case .draw, .marquee:
            break
        }
    }

    /// Rahmen der Rahmen-Auswahl in Ansichtspunkten, sonst `nil`.
    var marqueeRectInView: CGRect? {
        guard case .marquee = kind else { return nil }
        return CGRect(x: min(startInView.x, currentInView.x), y: min(startInView.y, currentInView.y),
                      width: abs(currentInView.x - startInView.x), height: abs(currentInView.y - startInView.y))
    }

    private var dragDistance: CGFloat { distance(to: currentInView) }

    private func distance(to inView: CGPoint) -> CGFloat {
        hypot(inView.x - startInView.x, inView.y - startInView.y)
    }

    // MARK: - Ablauf

    /// `shift`: Pfeile und Linien rasten in 45° ein, Formen bleiben proportional,
    /// Verschieben nur waagrecht oder senkrecht, Drehen in 15°-Schritten.
    mutating func update(to p: CGPoint, inView: CGPoint, shift: Bool, vm: EditorViewModel) {
        currentInView = inView
        switch kind {
        case let .draw(tool, id):
            if !isLive {
                guard dragDistance >= Self.minimumDrag else { return }
                vm.beginContinuousChange()
                isLive = true
            }
            guard let annotation = Self.makeAnnotation(tool, id: id, from: start, to: p, shift: shift) else { return }
            vm.applyLive { model in
                if let index = model.annotations.firstIndex(where: { $0.id == id }) {
                    model.annotations[index] = annotation
                } else {
                    model.annotations.append(annotation)
                }
            }
        case let .counter(annotation):
            let delta = CGVector(dx: p.x - start.x, dy: p.y - start.y)
            replace(AnnotationGeometry.moved(annotation, by: delta), vm: vm)
        case let .move(originals):
            var delta = CGVector(dx: p.x - start.x, dy: p.y - start.y)
            if shift {
                if abs(delta.dx) >= abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 }
            }
            vm.applyLive { model in
                for index in model.annotations.indices {
                    guard let original = originals[model.annotations[index].id] else { continue }
                    model.annotations[index] = AnnotationGeometry.moved(original, by: delta)
                }
            }
        case let .resize(handle, original):
            replace(AnnotationGeometry.resized(original, handle: handle, toOriginal: p, constrained: shift), vm: vm)
        case let .rotate(original):
            replace(AnnotationGeometry.rotated(original, toward: p, snap: shift), vm: vm)
        case let .marquee(base):
            let rect = CGRect(x: start.x, y: start.y, width: p.x - start.x, height: p.y - start.y)
            let hits = dragDistance >= Self.minimumDrag
                ? AnnotationGeometry.ids(intersecting: rect, in: vm.model.annotations) : []
            let selection = base.union(hits)
            if vm.selection != selection { vm.selection = selection }
        }
    }

    /// Loslassen: ein Undo-Schritt für den ganzen Zug. Neue Anmerkungen werden ausgewählt;
    /// neue Texte und Notizen (auch per Klick mit Standardrahmen) gehen in die Textbearbeitung.
    /// Endet ein Zeichen- oder Verschiebezug wieder nahe am Start oder entsteht eine Form ohne Fläche,
    /// wird er wie mit Esc verworfen.
    func finish(at p: CGPoint, inView: CGPoint, vm: EditorViewModel, settings: ToolSettings = .shared) {
        let backAtStart = distance(to: inView) < Self.minimumDrag
        switch kind {
        case let .draw(tool, id):
            if isLive {
                let drawn = vm.model.annotations.first { $0.id == id }
                if backAtStart || drawn.map(Self.isDegenerate) ?? true {
                    cancel(vm: vm)
                    return
                }
                if tool == .text || tool == .note {
                    // Der Schritt bleibt offen: Hinzufügen und Text werden ein Undo-Schritt der Bearbeitung.
                    vm.beginTextEditing(id, isNew: true)
                    return
                }
                vm.endContinuousChange(Self.addActionName(tool))
                vm.select(id, extend: false)
            } else if let annotation = Self.makeDefaultAnnotation(tool, id: id, at: p, settings: settings) {
                vm.beginContinuousChange()
                vm.applyLive { $0.annotations.append(annotation) }
                vm.beginTextEditing(id, isNew: true)
            }
        case let .counter(annotation):
            // Ein Klick setzt den Zähler genau auf den Klickpunkt.
            if backAtStart { replace(annotation, vm: vm) }
            vm.endContinuousChange(Self.addActionName(.counter))
            if vm.model.annotations.contains(where: { $0.id == annotation.id }) {
                vm.select(annotation.id, extend: false)
            }
        case .move:
            if backAtStart { return cancel(vm: vm) }
            vm.endContinuousChange(String(localized: "Bewegen"))
        case let .resize(handle, original):
            if let resized = vm.model.annotations.first(where: { $0.id == original.id }), Self.isDegenerate(resized) {
                return cancel(vm: vm)
            }
            let isPoint = [Handle.start, .end, .control].contains(handle)
            vm.endContinuousChange(isPoint ? String(localized: "Punkt verschieben") : String(localized: "Größe ändern"))
        case .rotate:
            vm.endContinuousChange(String(localized: "Drehen"))
        case .marquee:
            break
        }
    }

    /// Esc während des Zugs: alles wie vor dem Drücken, ohne Undo-Schritt.
    func cancel(vm: EditorViewModel) {
        switch kind {
        case let .marquee(base):
            vm.selection = base
        default:
            guard isLive else { return }
            vm.cancelContinuousChange()
        }
    }

    /// Ohne Fläche bzw. Länge (unter 1 px): Rechteckarten mit Breite oder Höhe 0, Pfeile und Linien ohne Länge.
    /// Bei Text zählt nur die Breite, die Höhe wächst mit dem Inhalt.
    static func isDegenerate(_ a: Annotation) -> Bool {
        switch a.kind {
        case let .arrow(start, end, _, _):
            hypot(end.x - start.x, end.y - start.y) < 1
        case let .shape(.line, rect, _):
            hypot(rect.size.width, rect.size.height) < 1
        case let .text(frame, _, _, _, _):
            abs(frame.width) < 1
        case let .shape(_, rect, _), let .note(rect, _, _), let .blur(rect, _, _), let .highlight(rect):
            abs(rect.width) < 1 || abs(rect.height) < 1
        case .counter:
            false
        }
    }

    private func replace(_ annotation: Annotation, vm: EditorViewModel) {
        vm.applyLive { model in
            guard let index = model.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
            model.annotations[index] = annotation
        }
    }

    // MARK: - Neue Anmerkungen

    static func addActionName(_ tool: EditorTool) -> String {
        switch tool {
        case .arrow: String(localized: "Pfeil hinzufügen")
        case .shape: String(localized: "Form hinzufügen")
        case .text: String(localized: "Text hinzufügen")
        case .note: String(localized: "Notiz hinzufügen")
        case .counter: String(localized: "Zähler hinzufügen")
        case .blur: String(localized: "Unschärfe hinzufügen")
        case .highlight: String(localized: "Marker hinzufügen")
        case .select, .crop: ""
        }
    }

    /// Die Anmerkung eines Zugs von `s` nach `e` mit den aktuellen Werkzeug-Optionen.
    static func makeAnnotation(_ tool: EditorTool, id: UUID, from s: CGPoint, to e: CGPoint, shift: Bool,
                               settings: ToolSettings = .shared) -> Annotation? {
        let rect = AnnotationGeometry.constrainedRect(from: s, to: e, proportional: shift)
        let kind: AnnotationKind
        switch tool {
        case .arrow:
            let end = shift ? AnnotationGeometry.snapAngle(from: s, to: e) : e
            let control = settings.arrowCurved ? ToolSettings.curvedControl(from: s, to: end) : nil
            kind = .arrow(start: s, end: end, control: control, head: settings.arrowHead)
        case .shape where settings.shapeKind == .line:
            let end = shift ? AnnotationGeometry.snapAngle(from: s, to: e) : e
            kind = .shape(kind: .line, rect: CGRect(x: s.x, y: s.y, width: end.x - s.x, height: end.y - s.y),
                          filled: false)
        case .shape:
            kind = .shape(kind: settings.shapeKind, rect: rect, filled: settings.shapeFilled)
        case .text:
            kind = .text(frame: rect, string: "", fontSize: settings.fontSize, bold: settings.textBold,
                         background: settings.textBackground)
        case .note:
            kind = .note(frame: rect, string: "", noteColor: settings.noteColor)
        case .blur:
            kind = .blur(rect: rect, mode: settings.blurMode, strength: settings.blurStrength)
        case .highlight:
            kind = .highlight(rect: rect)
        case .counter, .select, .crop:
            return nil
        }
        return Annotation(id: id, kind: kind, color: settings.color, strokeWidth: settings.strokeWidth)
    }

    /// Klick ohne Ziehen: Text (300 × Schriftgröße × 1,4, mittig auf der Klickhöhe) und Notiz (220 × 160)
    /// erhalten einen Standardrahmen ab dem Klickpunkt; andere Werkzeuge erzeugen nichts.
    static func makeDefaultAnnotation(_ tool: EditorTool, id: UUID, at p: CGPoint,
                                      settings: ToolSettings = .shared) -> Annotation? {
        let kind: AnnotationKind
        switch tool {
        case .text:
            let height = settings.fontSize * 1.4
            kind = .text(frame: CGRect(x: p.x, y: p.y - height / 2, width: 300, height: height), string: "",
                         fontSize: settings.fontSize, bold: settings.textBold, background: settings.textBackground)
        case .note:
            kind = .note(frame: CGRect(x: p.x, y: p.y, width: 220, height: 160), string: "",
                         noteColor: settings.noteColor)
        default:
            return nil
        }
        return Annotation(id: id, kind: kind, color: settings.color, strokeWidth: settings.strokeWidth)
    }

    /// Ein neuer Zähler am Klickpunkt: nächste freie Nummer ab dem Startwert, Radius max(14, Stärke × 3).
    static func makeCounter(at p: CGPoint, in annotations: [Annotation],
                            settings: ToolSettings = .shared) -> Annotation {
        let number = AnnotationGeometry.nextCounterNumber(in: annotations, start: settings.counterStart)
        let radius = max(14, settings.strokeWidth * 3)
        return Annotation(kind: .counter(center: p, number: number, radius: radius),
                          color: settings.color, strokeWidth: settings.strokeWidth)
    }
}
