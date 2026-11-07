import ScreenXCore
import SwiftUI

/// Kippen um die X- und Y-Achse (je ±30°), mit und ohne Gerät. Ein Reglerzug ist ein Undo-Schritt.
/// Solange gekippt ist, lassen sich Anmerkungen nicht bearbeiten (die Optionsleiste sagt das).
struct TiltControl: View {
    let vm: EditorViewModel

    var body: some View {
        let range = -TemplateGeometry.maxTilt...TemplateGeometry.maxTilt
        StyleSlider(vm: vm, title: String(localized: "X-Achse"), range: range,
                    actionName: String(localized: "Kippen"),
                    get: { $0.style.tilt.x }, set: { $0.style.tilt.x = $1 })
        StyleSlider(vm: vm, title: String(localized: "Y-Achse"), range: range,
                    actionName: String(localized: "Kippen"),
                    get: { $0.style.tilt.y }, set: { $0.style.tilt.y = $1 })
        Button(String(localized: "Zurücksetzen")) {
            vm.applyStyle(String(localized: "Kippen zurücksetzen")) { $0.style.tilt = .zero }
        }
        .disabled(vm.model.style.tilt == .zero)
    }
}
