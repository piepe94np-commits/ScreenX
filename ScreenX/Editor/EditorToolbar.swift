import SwiftUI

/// Werkzeugleiste des Editors (M2): Rückgängig/Wiederholen links, „Kopieren“ und „Sichern“ rechts.
/// Die Werkzeuge für Anmerkungen kommen in M3.
struct EditorToolbar: ToolbarContent {
    let vm: EditorViewModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                vm.undo()
            } label: {
                Label("Widerrufen", systemImage: "arrow.uturn.backward")
            }
            .help("Widerrufen")
            .disabled(!vm.canUndo)

            Button {
                vm.redo()
            } label: {
                Label("Wiederholen", systemImage: "arrow.uturn.forward")
            }
            .help("Wiederholen")
            .disabled(!vm.canRedo)
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Kopieren") {
                vm.copy()
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Sichern") {
                vm.quickSave(settings: vm.settingsProvider())
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
