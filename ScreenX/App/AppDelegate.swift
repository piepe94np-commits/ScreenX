import AppKit

/// Hält den `AppCoordinator`, öffnet `.screenx`-Dateien aus dem Finder und fragt beim Beenden
/// nach ungesicherten Editor-Änderungen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            coordinator.openDocument(at: url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = EditorWindowController.dirtyEditors
        guard !dirty.isEmpty else { return .terminateNow }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Es gibt ungesicherte Änderungen.")
        alert.addButton(withTitle: String(localized: "Alle sichern"))
        let discard = alert.addButton(withTitle: String(localized: "Nicht sichern"))
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: String(localized: "Abbrechen"))
        cancel.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for editor in dirty {
                editor.showWindow(nil)
                // Abgebrochen oder fehlgeschlagen: nicht beenden, die übrigen Fenster bleiben offen.
                guard editor.viewModel.saveProject() else { return .terminateCancel }
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
