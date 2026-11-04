import ScreenXCore
import SwiftUI

/// Farbfelder (8 Annotationsfarben bzw. 5 Notizfarben), optional mit Farbwähler.
/// `pick` ist eine einzelne Wahl (ein Undo-Schritt), `customPick` meldet die vielen Änderungen
/// aus dem Farbfenster.
struct ColorPaletteView: View {
    let colors: [ColorValue]
    let current: ColorValue?
    var allowsCustom = true
    let pick: (ColorValue) -> Void
    var customPick: (ColorValue) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { color in
                swatch(color)
            }
            if allowsCustom {
                ColorPicker(String(localized: "Eigene Farbe"), selection: customBinding, supportsOpacity: false)
                    .labelsHidden()
                    .help(String(localized: "Eigene Farbe"))
            }
        }
    }

    private func swatch(_ color: ColorValue) -> some View {
        let selected = current.map { Self.sameRGB($0, color) } ?? false
        return Button {
            pick(color)
        } label: {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 1))
                .frame(width: 18, height: 18)
                .padding(2)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(color.hex)
        .accessibilityLabel(color.hex)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customBinding: Binding<CGColor> {
        Binding(
            get: { (current ?? AnnotationPalette.defaultColor).cgColor },
            set: { cgColor in
                guard let color = ColorValue(converting: cgColor) else { return }
                customPick(color)
            })
    }

    private static func sameRGB(_ a: ColorValue, _ b: ColorValue) -> Bool {
        a.hex.prefix(7) == b.hex.prefix(7)
    }
}
