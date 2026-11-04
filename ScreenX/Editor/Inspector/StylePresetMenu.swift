import AppKit
import ScreenXCore
import SwiftUI

/// Menü „Stile“: aktuellen Stil sichern, gespeicherte Stile anwenden oder löschen.
struct StylePresetMenu: View {
    let vm: EditorViewModel

    @State private var presets: [StylePreset] = []

    var body: some View {
        Menu(String(localized: "Stile")) {
            Button(String(localized: "Aktuellen Stil sichern …"), action: saveCurrent)
            if !presets.isEmpty {
                Divider()
                ForEach(presets) { preset in
                    Button(preset.name) { apply(preset) }
                }
                Divider()
                Menu(String(localized: "Löschen")) {
                    ForEach(presets) { preset in
                        Button(preset.name, role: .destructive) { delete(preset) }
                    }
                }
            }
        }
        .fixedSize()
        .onAppear(perform: reload)
    }

    private func reload() {
        presets = StylePresetStore.shared.presets()
    }

    private func apply(_ preset: StylePreset) {
        // Das Bild eines Bild-Hintergrunds gehört zum Dokument, nicht zur Vorlage.
        var ownImage: Background?
        if vm.backgroundImage != nil, let ext = vm.backgroundExtension { ownImage = .image(file: "background.\(ext)") }
        vm.applyStyle(String(localized: "Stil „\(preset.name)“")) { model in
            let background = model.style.background
            model.style = preset.style
            if case .image = preset.style.background {
                model.style.background = ownImage ?? background
            }
        }
    }

    private func delete(_ preset: StylePreset) {
        StylePresetStore.shared.delete(id: preset.id)
        reload()
    }

    private func saveCurrent() {
        guard let name = Self.askName() else { return }
        StylePresetStore.shared.save(StylePreset(name: name, style: vm.model.style))
        reload()
    }

    /// Fragt den Namen der neuen Vorlage ab; `nil` bei Abbruch oder leerem Namen.
    private static func askName() -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Aktuellen Stil sichern")
        alert.informativeText = String(localized: "Name der Vorlage:")
        alert.addButton(withTitle: String(localized: "Sichern"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Mein Stil")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
