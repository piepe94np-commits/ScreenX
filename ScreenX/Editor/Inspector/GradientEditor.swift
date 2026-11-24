import AppKit
import ScreenXCore
import SwiftUI

/// „Eigener Verlauf“: 2–3 Farben und Winkel. Jede Änderung schaltet den Hintergrund
/// auf `.gradient` mit den bearbeiteten Farbstopps.
struct GradientEditor: View {
    let vm: EditorViewModel
    let colorEdit: ColorEditSession

    /// Stopps und Winkel des aktuellen Verlaufs, sonst der ersten Vorlage.
    private var current: (stops: [GradientStop], angle: Double) {
        if case let .gradient(stops, angle) = vm.model.style.background { return (stops, angle) }
        if case let .gradient(stops, angle) = GradientPresets.all[0] { return (stops, angle) }
        return ([], 135)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Eigener Verlauf")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                ForEach(current.stops.indices, id: \.self) { index in
                    ColorPicker(String(localized: "Farbe \(index + 1)"), selection: colorBinding(index),
                                supportsOpacity: false)
                        .labelsHidden()
                }
                Spacer(minLength: 0)
                Button(String(localized: "+ Farbe")) { setStopCount(3) }
                    .disabled(current.stops.count >= 3)
                Button(String(localized: "− Farbe")) { setStopCount(2) }
                    .disabled(current.stops.count <= 2)
            }
            StyleSlider(vm: vm, title: String(localized: "Winkel"), range: 0...360,
                        actionName: String(localized: "Verlaufswinkel"),
                        get: { model in
                            if case let .gradient(_, angle) = model.style.background { return angle }
                            return 135
                        },
                        set: { [stops = current.stops] model, angle in
                            var currentStops = stops
                            if case let .gradient(s, _) = model.style.background { currentStops = s }
                            model.style.background = .gradient(stops: currentStops, angle: angle)
                        })
        }
    }

    private func colorBinding(_ index: Int) -> Binding<CGColor> {
        Binding(
            get: {
                let stops = current.stops
                return stops.indices.contains(index) ? stops[index].color.cgColor : .white
            },
            set: { cgColor in
                guard let color = ColorValue(converting: cgColor) else { return }
                let (stops, angle) = current
                guard stops.indices.contains(index) else { return }
                var edited = stops
                edited[index].color = color
                colorEdit.change(vm, String(localized: "Verlaufsfarbe")) {
                    $0.style.background = .gradient(stops: edited, angle: angle)
                }
            })
    }

    /// Fügt eine Farbe hinzu oder entfernt die letzte; die Stopps werden gleichmäßig verteilt.
    private func setStopCount(_ count: Int) {
        let (stops, angle) = current
        var colors = stops.map(\.color)
        guard let last = colors.last else { return }
        while colors.count < count { colors.append(last) }
        colors = Array(colors.prefix(count))
        let edited = colors.enumerated().map { index, color in
            GradientStop(color: color, location: Double(index) / Double(max(1, count - 1)))
        }
        colorEdit.finish(vm)
        let name = count > stops.count ? String(localized: "Farbe hinzufügen") : String(localized: "Farbe entfernen")
        vm.applyStyle(name) { $0.style.background = .gradient(stops: edited, angle: angle) }
    }
}

/// Fasst die vielen Änderungen aus dem Farbfenster zu einem Undo-Schritt zusammen:
/// der Schritt endet 0,5 s nach der letzten Änderung oder früher, wenn das ViewModel ihn
/// vor einer anderen Änderung bzw. vor Undo/Redo abschließt.
@MainActor
final class ColorEditSession {
    private var endTask: Task<Void, Never>?
    /// Merkt am Ende eines Schritts den Stil als „zuletzt verwendet“ (Inspektor). Änderungen an
    /// Anmerkungen ändern den Stil nicht und dürfen den gemerkten Stil nicht überschreiben.
    private let remembersStyle: Bool

    init(remembersStyle: Bool = true) {
        self.remembersStyle = remembersStyle
    }

    func change(_ vm: EditorViewModel, _ actionName: String, _ edit: (inout DocumentModel) -> Void) {
        vm.beginPendingEdit(actionName)
        vm.applyLive(edit)
        endTask?.cancel()
        let remembersStyle = remembersStyle
        endTask = Task { [weak self, weak vm] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let vm else { return }
            self?.endTask = nil
            vm.flushPendingEdit()
            if remembersStyle { vm.rememberStyle() }
        }
    }

    /// Schließt einen offenen Schritt sofort ab (z. B. vor einer anderen Änderung).
    func finish(_ vm: EditorViewModel) {
        endTask?.cancel()
        endTask = nil
        vm.flushPendingEdit()
    }
}

extension ColorValue {
    /// sRGB-Komponenten einer beliebigen `CGColor`; `nil`, wenn sie sich nicht umrechnen lässt.
    init?(converting cgColor: CGColor) {
        guard let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return nil }
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                  alpha: color.alphaComponent)
    }
}
