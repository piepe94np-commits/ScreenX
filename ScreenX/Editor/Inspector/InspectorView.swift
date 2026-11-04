import ScreenXCore
import SwiftUI

/// Inspektor rechts im Editor mit den Reitern „Stil“ und „Export“.
/// Den Reiter „Vorlage“ gibt es erst in M4.
struct InspectorView: View {
    let vm: EditorViewModel
    @Binding var settings: AppSettings

    private enum InspectorTab: Hashable { case style, export }

    @State private var tab: InspectorTab = .style

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Reiter"), selection: $tab) {
                Text("Stil").tag(InspectorTab.style)
                Text("Export").tag(InspectorTab.export)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .style:
                        StyleSection(vm: vm)
                            // Dokumente einer neueren Version sind nur zum Ansehen.
                            .disabled(vm.isReadOnly)
                    case .export:
                        ExportSection(vm: vm, settings: $settings)
                    }
                }
            }
        }
        .controlSize(.small)
    }
}

/// Abschnitt mit kleiner grauer Überschrift in Großbuchstaben und Trennlinie darunter.
struct InspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Reglerzeile: Bezeichnung (78 pt), Regler und Zahlenfeld (34 pt, rechtsbündig).
/// Ein Reglerzug ergibt genau einen Undo-Schritt; eine Eingabe im Zahlenfeld ebenso.
/// Werte sind ganzzahlig (Schrittweite 1), wie im Zahlenfeld.
struct StyleSlider: View {
    let vm: EditorViewModel
    let title: String
    let range: ClosedRange<Double>
    let actionName: String
    let get: @Sendable (DocumentModel) -> Double
    let set: @Sendable (inout DocumentModel, Double) -> Void

    @State private var isEditing = false
    /// Erzwingt die Neuanzeige des Zahlenfelds, wenn eine Eingabe auf den Bereich begrenzt wurde.
    @State private var fieldRevision = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)
            Slider(value: sliderValue, in: range, step: 1) { editing in
                isEditing = editing
                if editing {
                    vm.beginContinuousChange()
                } else {
                    vm.endStyleChange(actionName)
                }
            }
            TextField(title, value: fieldValue, format: IntegerFormatStyle<Int>())
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 34)
                .id(fieldRevision)
        }
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { get(vm.model) },
            set: { value in
                if isEditing {
                    vm.applyLive { set(&$0, value) }
                } else {
                    // Tastatur oder Bedienungshilfen: ohne Reglerzug ein einzelner Schritt.
                    vm.applyStyle(actionName) { set(&$0, value) }
                }
            })
    }

    private var fieldValue: Binding<Int> {
        Binding(
            get: { Int(get(vm.model).rounded()) },
            set: { value in
                let clamped = min(max(Double(value), range.lowerBound), range.upperBound)
                if clamped != Double(value) { fieldRevision += 1 }
                // Unverändert: kein Undo-Schritt (und abgeleitete Schattenwerte bleiben automatisch).
                guard Int(clamped) != Int(get(vm.model).rounded()) else { return }
                vm.applyStyle(actionName) { set(&$0, clamped) }
            })
    }
}

extension EditorViewModel {
    /// Eine Stiländerung als ein Undo-Schritt; der Stil wird als „zuletzt verwendet“ gemerkt.
    func applyStyle(_ actionName: String, _ change: (inout DocumentModel) -> Void) {
        apply(actionName, change)
        rememberStyle()
    }

    /// Schließt einen Reglerzug ab und merkt den Stil.
    func endStyleChange(_ actionName: String) {
        endContinuousChange(actionName)
        rememberStyle()
    }

    func rememberStyle() {
        guard !isReadOnly else { return }
        StylePresetStore.shared.setLastStyle(model.style)
    }
}

extension StylePresetStore {
    /// Gemeinsamer Speicher für Stil-Vorlagen und den zuletzt verwendeten Stil.
    static let shared = StylePresetStore(defaults: .standard)
}
