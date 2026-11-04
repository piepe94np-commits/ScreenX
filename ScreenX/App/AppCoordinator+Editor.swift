import AppKit
import OSLog
import ScreenXCore
import SwiftUI

/// Editor öffnen (aus Schnellzugriff, Menü und Finder) und Einstellungen zeigen.
extension AppCoordinator {
    /// Öffnet eine Aufnahme im Editor, mit dem zuletzt genutzten Stil (falls eingestellt).
    func openEditor(for capture: Capture) {
        let style = Style.forNewCapture(
            lastStyle: StylePresetStore.shared.lastStyle(), applyLastStyle: settings.applyLastStyle)
        let vm = EditorViewModel(capture: capture, style: style, settings: settingsProvider)
        // Vom Benutzer ausgelöst: `open` aktiviert ScreenX.
        EditorWindowController.open(vm, settings: Bindable(self).settings)
    }

    func editLastCapture() {
        guard let lastCapture else { return }
        openEditor(for: lastCapture)
    }

    /// Öffnet ein Projekt oder holt sein Fenster nach vorn. Fehler erscheinen als Hinweisfenster.
    func openDocument(at url: URL) {
        NSApp.activate()
        EditorViewModel.open(url: url, settings: settingsProvider)
    }

    /// „Datei öffnen …“: Auswahldialog für Projekte.
    func chooseDocuments() {
        NSApp.activate()
        EditorViewModel.openProject(settings: settingsProvider)
    }

    /// Merkt sich die SwiftUI-Aktion zum Öffnen der Einstellungen.
    func register(openSettings: OpenSettingsAction) {
        openSettingsAction = openSettings
    }

    /// Zeigt das Einstellungsfenster wie „Einstellungen …“ im Menüleisten-Menü.
    func showSettings() {
        NSApp.activate()
        if let openSettingsAction {
            openSettingsAction()
        } else if !EditorMenu.performPreviousSettingsItem() {
            AppCoordinator.logger.error("Einstellungen konnten nicht geöffnet werden")
        }
    }

    private var settingsProvider: () -> AppSettings {
        { [weak self] in self?.settings ?? .defaults(home: FileManager.default.homeDirectoryForCurrentUser) }
    }
}
