import ScreenXCore
import SwiftUI

/// Schmale Leiste unter der Werkzeugleiste. Ohne Auswahl zeigt sie die Optionen des aktiven Werkzeugs
/// (gespeichert in `ToolSettings`), mit Auswahl die Optionen der ausgewählten Anmerkungen.
/// Änderungen an einer Auswahl wirken auf alle ausgewählten Anmerkungen, deren Art sie kennt,
/// als ein Undo-Schritt. Farbe und Strichstärke werden außerdem als „zuletzt genutzt“ gemerkt.
struct ToolOptionsBar: View {
    let vm: EditorViewModel
    private var settings: ToolSettings { .shared }

    @State private var colorEdit = ColorEditSession(remembersStyle: false)

    /// Optionsgruppen, in der Reihenfolge der Anzeige.
    private enum OptionGroup: CaseIterable { case color, stroke, arrow, shape, text, note, counter, blur }

    private var selected: [Annotation] {
        vm.model.annotations.filter { vm.selection.contains($0.id) }
    }

    private var isSelection: Bool { !selected.isEmpty }

    var body: some View {
        HStack(spacing: 16) {
            let groups = isSelection ? Self.groups(for: selected) : Self.groups(for: vm.tool)
            if groups.isEmpty {
                Text(hint)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.self) { group in
                view(for: group)
            }
            Spacer(minLength: 0)
            if isSelection { arrangeButtons }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .disabled(vm.isReadOnly)
        .onChange(of: vm.selection) { colorEdit.finish(vm) }
    }

    private var hint: String {
        switch vm.tool {
        case .crop: String(localized: "Rahmen ziehen, um das Bild zuzuschneiden.")
        default: String(localized: "Anmerkung anklicken, um sie zu bearbeiten.")
        }
    }

    // MARK: - Gruppen

    private static func groups(for tool: EditorTool) -> [OptionGroup] {
        switch tool {
        case .select, .crop: []
        case .arrow: [.color, .stroke, .arrow]
        case .shape: [.color, .stroke, .shape]
        case .text: [.color, .text]
        case .note: [.note]
        case .counter: [.color, .counter]
        case .blur: [.blur]
        case .highlight: [.color]
        }
    }

    private static func groups(for annotations: [Annotation]) -> [OptionGroup] {
        var found: Set<OptionGroup> = []
        for annotation in annotations {
            switch annotation.kind {
            case .arrow: found.formUnion([.color, .stroke, .arrow])
            case .shape: found.formUnion([.color, .stroke, .shape])
            case .text: found.formUnion([.color, .text])
            case .note: found.insert(.note)
            case .counter, .highlight: found.insert(.color)
            case .blur: found.insert(.blur)
            }
        }
        return OptionGroup.allCases.filter(found.contains)
    }

    @ViewBuilder private func view(for group: OptionGroup) -> some View {
        switch group {
        case .color: colorOptions
        case .stroke: strokeOptions
        case .arrow: arrowOptions
        case .shape: shapeOptions
        case .text: textOptions
        case .note: noteOptions
        case .counter: counterOptions
        case .blur: blurOptions
        }
    }

    // MARK: - Änderungen

    /// Eine einzelne Änderung: an der Auswahl als ein Undo-Schritt, sonst an den Werkzeug-Optionen.
    private func edit(_ name: String, tool: () -> Void, annotation: (inout Annotation) -> Void) {
        if isSelection {
            colorEdit.finish(vm)
            vm.applyToSelection(name, annotation)
        } else {
            tool()
        }
    }

    /// Eine Änderung aus dem Farbfenster: an der Auswahl zusammengefasst zu einem Undo-Schritt.
    private func editFromColorPanel(_ name: String, tool: () -> Void, annotation: (inout Annotation) -> Void) {
        guard isSelection else { return tool() }
        let ids = vm.selection
        colorEdit.change(vm, name) { model in
            for index in model.annotations.indices where ids.contains(model.annotations[index].id) {
                annotation(&model.annotations[index])
            }
        }
    }

    /// Regler: an der Auswahl ein Undo-Schritt je Zug, sonst direkt an den Werkzeug-Optionen.
    /// `remember` merkt den Wert an einer Auswahl als „zuletzt genutzt“: einmal je Zug bzw. Schritt,
    /// nicht bei jedem Zwischenwert.
    private func slider(_ title: String, actionName: String, range: ClosedRange<Double>, value: Double,
                        tool: @escaping (Double) -> Void,
                        remember: @escaping (Double) -> Void = { _ in },
                        annotation: @escaping (inout Annotation, Double) -> Void) -> some View {
        OptionSlider(
            title: title, range: range, value: value,
            begin: { if isSelection { vm.beginContinuousChange() } },
            change: { newValue, live in
                if isSelection {
                    if live {
                        vm.applyLiveToSelection { annotation(&$0, newValue) }
                    } else {
                        colorEdit.finish(vm)
                        vm.applyToSelection(actionName) { annotation(&$0, newValue) }
                        remember(newValue)
                    }
                } else {
                    tool(newValue)
                }
            },
            end: { lastValue in
                guard isSelection else { return }
                vm.endContinuousChange(actionName)
                if let lastValue { remember(lastValue) }
            })
    }

    // MARK: - Farbe und Stärke

    private var currentColor: ColorValue {
        guard isSelection else { return settings.color }
        return selected.first(where: \.supportsColor)?.color ?? settings.color
    }

    private var colorOptions: some View {
        let name = String(localized: "Farbe")
        return ColorPaletteView(
            colors: AnnotationPalette.colors, current: currentColor,
            pick: { color in
                settings.color = color
                edit(name, tool: {}, annotation: { if $0.supportsColor { $0.color = color } })
            },
            customPick: { color in
                settings.color = color
                editFromColorPanel(name, tool: {}, annotation: { if $0.supportsColor { $0.color = color } })
            })
    }

    private var strokeOptions: some View {
        let value = isSelection
            ? selected.first(where: \.supportsStrokeWidth)?.strokeWidth ?? settings.strokeWidth
            : settings.strokeWidth
        return slider(String(localized: "Stärke"), actionName: String(localized: "Strichstärke"),
                      range: 1...40, value: value,
                      tool: { settings.strokeWidth = $0 },
                      remember: { settings.strokeWidth = $0 },
                      annotation: { a, width in
                          if a.supportsStrokeWidth { a.strokeWidth = width }
                      })
    }

    // MARK: - Pfeil

    private var arrowOptions: some View {
        let arrow = isSelection ? selected.lazy.compactMap(\.arrowAttributes).first : nil
        let curved = arrow?.curved ?? settings.arrowCurved
        let head = arrow?.head ?? settings.arrowHead
        return HStack(spacing: 8) {
            Picker(String(localized: "Pfeilform"), selection: Binding(
                get: { curved },
                set: { value in
                    edit(String(localized: "Pfeilform"), tool: { settings.arrowCurved = value }) { a in
                        guard case let .arrow(start, end, control, head) = a.kind else { return }
                        let newControl: CGPoint? = value ? control ?? ToolSettings.curvedControl(from: start, to: end) : nil
                        a.kind = .arrow(start: start, end: end, control: newControl, head: head)
                    }
                }
            )) {
                Text("Gerade").tag(false)
                Text("Gebogen").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker(String(localized: "Pfeilspitze"), selection: Binding(
                get: { head },
                set: { value in
                    edit(String(localized: "Pfeilspitze"), tool: { settings.arrowHead = value }) { a in
                        guard case let .arrow(start, end, control, _) = a.kind else { return }
                        a.kind = .arrow(start: start, end: end, control: control, head: value)
                    }
                }
            )) {
                Text("Gefüllt").tag(ArrowHead.filled)
                Text("Offen").tag(ArrowHead.open)
                Text("Beidseitig").tag(ArrowHead.double)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - Form

    private var shapeOptions: some View {
        let shape = isSelection ? selected.lazy.compactMap(\.shapeAttributes).first : nil
        let kind = shape?.kind ?? settings.shapeKind
        let filled = shape?.filled ?? settings.shapeFilled
        // Linien haben keine Füllung: gesperrt nur, wenn keine ausgewählte Form sie nutzen kann.
        let onlyLines = isSelection
            ? selected.compactMap(\.shapeAttributes).allSatisfy { $0.kind == .line }
            : kind == .line
        return HStack(spacing: 8) {
            Picker(String(localized: "Formart"), selection: Binding(
                get: { kind },
                set: { value in
                    edit(String(localized: "Formart"), tool: { settings.shapeKind = value }) { a in
                        guard case let .shape(_, rect, filled) = a.kind else { return }
                        a.kind = .shape(kind: value, rect: rect, filled: filled)
                    }
                }
            )) {
                Label("Rechteck", systemImage: "rectangle").tag(ShapeKind.rectangle)
                Label("Abgerundetes Rechteck", systemImage: "app").tag(ShapeKind.roundedRectangle)
                Label("Ellipse", systemImage: "circle").tag(ShapeKind.ellipse)
                Label("Linie", systemImage: "line.diagonal").tag(ShapeKind.line)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()

            Picker(String(localized: "Füllung"), selection: Binding(
                get: { filled },
                set: { value in
                    edit(String(localized: "Füllung"), tool: { settings.shapeFilled = value }) { a in
                        guard case let .shape(kind, rect, _) = a.kind else { return }
                        a.kind = .shape(kind: kind, rect: rect, filled: value)
                    }
                }
            )) {
                Text("Kontur").tag(false)
                Text("Gefüllt").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(onlyLines)
        }
    }

    // MARK: - Text

    private var textOptions: some View {
        let text = isSelection ? selected.lazy.compactMap(\.textAttributes).first : nil
        let fontSize = text?.fontSize ?? settings.fontSize
        let bold = text?.bold ?? settings.textBold
        let background = text.map(\.background) ?? settings.textBackground
        let backgroundName = String(localized: "Text-Hintergrund")
        func setBackground(_ value: ColorValue?, fromPanel: Bool) {
            let apply: (inout Annotation) -> Void = { a in
                guard case let .text(frame, string, size, bold, _) = a.kind else { return }
                a.kind = .text(frame: frame, string: string, fontSize: size, bold: bold, background: value)
            }
            if fromPanel {
                editFromColorPanel(backgroundName, tool: { settings.textBackground = value }, annotation: apply)
            } else {
                edit(backgroundName, tool: { settings.textBackground = value }, annotation: apply)
            }
        }
        return HStack(spacing: 8) {
            slider(String(localized: "Größe"), actionName: String(localized: "Schriftgröße"),
                   range: 8...200, value: fontSize,
                   tool: { settings.fontSize = $0 },
                   annotation: { a, size in
                       guard case let .text(frame, string, _, bold, background) = a.kind else { return }
                       a.kind = .text(frame: frame, string: string, fontSize: size, bold: bold, background: background)
                   })

            Toggle(isOn: Binding(
                get: { bold },
                set: { value in
                    edit(String(localized: "Fett"), tool: { settings.textBold = value }) { a in
                        guard case let .text(frame, string, size, _, background) = a.kind else { return }
                        a.kind = .text(frame: frame, string: string, fontSize: size, bold: value, background: background)
                    }
                }
            )) {
                Label("Fett", systemImage: "bold")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(String(localized: "Fett"))

            Toggle(String(localized: "Hintergrund"), isOn: Binding(
                get: { background != nil },
                set: { on in setBackground(on ? ColorValue(red: 1, green: 1, blue: 1) : nil, fromPanel: false) }
            ))
            .toggleStyle(.checkbox)

            if let background {
                ColorPicker(backgroundName, selection: Binding(
                    get: { background.cgColor },
                    set: { cgColor in
                        guard let color = ColorValue(converting: cgColor) else { return }
                        setBackground(color, fromPanel: true)
                    }), supportsOpacity: true)
                    .labelsHidden()
                    .help(backgroundName)
            }
        }
    }

    // MARK: - Notiz, Zähler, Unschärfe

    private var noteOptions: some View {
        let current = (isSelection ? selected.lazy.compactMap(\.noteColor).first : nil) ?? settings.noteColor
        return ColorPaletteView(
            colors: AnnotationPalette.noteColors, current: current, allowsCustom: false,
            pick: { color in
                edit(String(localized: "Notizfarbe"), tool: { settings.noteColor = color }) { a in
                    guard case let .note(frame, string, _) = a.kind else { return }
                    a.kind = .note(frame: frame, string: string, noteColor: color)
                }
            })
    }

    private var counterOptions: some View {
        Stepper(value: Binding(get: { settings.counterStart }, set: { settings.counterStart = $0 }),
                in: 1...999) {
            Text("Startwert \(settings.counterStart)")
                .monospacedDigit()
        }
    }

    private var blurOptions: some View {
        let blur = isSelection ? selected.lazy.compactMap(\.blurAttributes).first : nil
        let mode = blur?.mode ?? settings.blurMode
        let strength = blur?.strength ?? settings.blurStrength
        return HStack(spacing: 8) {
            Picker(String(localized: "Unschärfe-Art"), selection: Binding(
                get: { mode },
                set: { value in
                    edit(String(localized: "Unschärfe-Art"), tool: { settings.blurMode = value }) { a in
                        guard case let .blur(rect, _, strength) = a.kind else { return }
                        a.kind = .blur(rect: rect, mode: value, strength: strength)
                    }
                }
            )) {
                Text("Weichzeichnen").tag(BlurMode.blur)
                Text("Verpixeln").tag(BlurMode.pixelate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            slider(String(localized: "Stärke"), actionName: String(localized: "Unschärfe-Stärke"),
                   range: 1...60, value: strength,
                   tool: { settings.blurStrength = $0 },
                   annotation: { a, value in
                       guard case let .blur(rect, mode, _) = a.kind else { return }
                       a.kind = .blur(rect: rect, mode: mode, strength: value)
                   })
        }
    }

    // MARK: - Ebenen

    private var arrangeButtons: some View {
        HStack(spacing: 4) {
            Button { vm.sendBackward() } label: {
                Label("Nach hinten", systemImage: "square.2.layers.3d.bottom.filled")
            }
            .help(String(localized: "Nach hinten (⌘[)"))
            Button { vm.bringForward() } label: {
                Label("Nach vorne", systemImage: "square.2.layers.3d.top.filled")
            }
            .help(String(localized: "Nach vorne (⌘])"))
            Button { vm.duplicateSelection() } label: {
                Label("Duplizieren", systemImage: "plus.square.on.square")
            }
            .help(String(localized: "Duplizieren (⌘D)"))
            Button { vm.deleteSelection() } label: {
                Label("Löschen", systemImage: "trash")
            }
            .help(String(localized: "Löschen (⌫)"))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

/// Regler mit Titel und Zahl. `change` meldet, ob der Wert aus einem laufenden Zug stammt (`live`).
private struct OptionSlider: View {
    let title: String
    let range: ClosedRange<Double>
    let value: Double
    let begin: () -> Void
    let change: (Double, Bool) -> Void
    /// Meldet den letzten Wert des Zugs (`nil`, wenn er sich nicht geändert hat).
    let end: (Double?) -> Void

    @State private var isEditing = false
    @State private var lastValue: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: { newValue in
                if isEditing { lastValue = newValue }
                change(newValue, isEditing)
            }), in: range, step: 1) { editing in
                isEditing = editing
                if editing {
                    lastValue = nil
                    begin()
                } else {
                    end(lastValue)
                    lastValue = nil
                }
            }
            .frame(width: 100)
            Text(value, format: .number.precision(.fractionLength(0)))
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
        }
    }
}

extension Annotation {
    /// Die Art nutzt `color` (Notiz und Unschärfe nicht).
    var supportsColor: Bool {
        switch kind {
        case .arrow, .shape, .text, .counter, .highlight: true
        case .note, .blur: false
        }
    }

    /// Die Art nutzt `strokeWidth`.
    var supportsStrokeWidth: Bool {
        switch kind {
        case .arrow, .shape: true
        default: false
        }
    }

    fileprivate var arrowAttributes: (curved: Bool, head: ArrowHead)? {
        guard case let .arrow(_, _, control, head) = kind else { return nil }
        return (control != nil, head)
    }

    fileprivate var shapeAttributes: (kind: ShapeKind, filled: Bool)? {
        guard case let .shape(kind, _, filled) = kind else { return nil }
        return (kind, filled)
    }

    fileprivate var textAttributes: (fontSize: Double, bold: Bool, background: ColorValue?)? {
        guard case let .text(_, _, fontSize, bold, background) = kind else { return nil }
        return (fontSize, bold, background)
    }

    fileprivate var noteColor: ColorValue? {
        guard case let .note(_, _, noteColor) = kind else { return nil }
        return noteColor
    }

    fileprivate var blurAttributes: (mode: BlurMode, strength: Double)? {
        guard case let .blur(_, mode, strength) = kind else { return nil }
        return (mode, strength)
    }
}
