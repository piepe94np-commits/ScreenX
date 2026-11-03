import AppKit
import ScreenXCore
import SwiftUI

/// Inhalt des Menüleisten-Menüs.
struct MenuBarContent: View {
    let coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ForEach(CaptureMode.allCases, id: \.self) { mode in
            Button(title(for: mode)) {
                // Das Menü schließt zuerst; die Aufnahme startet im nächsten Durchlauf,
                // damit das Menü nicht im eingefrorenen Bild landet.
                Task { @MainActor in await coordinator.capture(mode) }
            }
        }

        Divider()

        Button(String(localized: "Letzte Aufnahme anzeigen")) {
            coordinator.showLastCapture()
        }
        .disabled(coordinator.lastCapture == nil)

        Button(String(localized: "Einstellungen …")) {
            // Als LSUIElement-App muss ScreenX aktiviert werden, damit das Fenster nach vorne kommt.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Button(String(localized: "Beenden")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Menütitel mit dem eingestellten Kürzel als Text dahinter (globale Kürzel lassen sich
    /// nicht als `keyboardShortcut` darstellen).
    private func title(for mode: CaptureMode) -> String {
        guard let combo = coordinator.settings.hotkeys[mode] else { return mode.title }
        return "\(mode.title)   \(combo.displayString)"
    }
}

extension CaptureMode {
    /// Deutscher Titel für Menü und Einstellungen.
    var title: String {
        switch self {
        case .area: String(localized: "Bereich aufnehmen")
        case .window: String(localized: "Fenster aufnehmen")
        case .fullscreen: String(localized: "Vollbild aufnehmen")
        }
    }
}
