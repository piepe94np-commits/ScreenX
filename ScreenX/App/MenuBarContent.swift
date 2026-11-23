import AppKit
import ScreenXCore
import SwiftUI

/// Inhalt des Menüleisten-Menüs.
struct MenuBarContent: View {
    let coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Für „Einstellungen …“ im Editor-Menü (AppKit hat keinen eigenen Weg zur Settings-Scene).
        let _ = coordinator.register(openSettings: openSettings)

        if coordinator.videoRecorder.isRecording {
            RecordingMenuSection(recorder: coordinator.videoRecorder, hotkey: coordinator.settings.videoHotkey)
            Divider()
        }

        ForEach(CaptureMode.allCases, id: \.self) { mode in
            Button(title(for: mode)) {
                // Das Menü schließt zuerst; die Aufnahme startet im nächsten Durchlauf,
                // damit das Menü nicht im eingefrorenen Bild landet.
                Task { @MainActor in await coordinator.capture(mode) }
            }
        }

        if coordinator.videoRecorder.phase == .idle {
            Button(videoTitle) {
                // Erst nach dem Schließen des Menüs, damit die Leiste Key werden kann.
                Task { @MainActor in coordinator.videoRecorder.toggle() }
            }
        }

        Divider()

        Button(String(localized: "Letzte Aufnahme anzeigen")) {
            coordinator.showLastCapture()
        }
        .disabled(coordinator.lastCapture == nil)

        Button(String(localized: "Letzte Aufnahme bearbeiten")) {
            coordinator.editLastCapture()
        }
        .disabled(coordinator.lastCapture == nil)

        Button(String(localized: "Datei öffnen …")) {
            // Erst nach dem Schließen des Menüs: der Dialog läuft modal.
            Task { @MainActor in coordinator.chooseDocuments() }
        }

        Divider()

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

    private var videoTitle: String {
        let title = String(localized: "Video aufnehmen …")
        guard let combo = coordinator.settings.videoHotkey else { return title }
        return "\(title)   \(combo.displayString)"
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

/// Menüteil während einer Videoaufnahme (Figma-Rahmen 3).
private struct RecordingMenuSection: View {
    let recorder: RecordingCoordinator
    let hotkey: KeyCombo?

    var body: some View {
        switch recorder.engine.state {
        case .finishing:
            Text(String(localized: "Wird gesichert …"))
        case .paused:
            Text(String(localized: "● Aufnahme pausiert · \(recorder.elapsedText)"))
        case .recording, .idle:
            Text(String(localized: "● Aufnahme läuft · \(recorder.elapsedText)"))
        }
        Text(recorder.infoLine)

        Divider()

        Button(stopTitle) { recorder.stop() }
            .disabled(recorder.engine.state == .finishing)
        Button(recorder.engine.state == .paused ? String(localized: "Fortsetzen") : String(localized: "Pause")) {
            recorder.togglePause()
        }
        .disabled(recorder.engine.state == .finishing)
        Button(String(localized: "Verwerfen …")) {
            // Die Rückfrage läuft modal, also erst nach dem Schließen des Menüs.
            Task { @MainActor in recorder.discard() }
        }
        .disabled(recorder.engine.state == .finishing)
    }

    private var stopTitle: String {
        let title = String(localized: "Aufnahme beenden")
        guard let hotkey else { return title }
        return "\(title)   \(hotkey.displayString)"
    }
}

/// Menüleisten-Symbol: im Ruhezustand die Kamera, während der Aufnahme ein roter Punkt mit Laufzeit
/// (in der Pause blinkend), beim Fertigstellen „Wird gesichert …“.
struct MenuBarLabel: View {
    let recorder: RecordingCoordinator

    var body: some View {
        if recorder.isRecording {
            if recorder.engine.state == .finishing {
                Text(String(localized: "Wird gesichert …"))
            } else {
                Image(nsImage: RecordingBadge.image(
                    text: recorder.elapsedText,
                    showsText: recorder.engine.state != .paused || recorder.blinkOn))
            }
        } else {
            Image(systemName: "camera.viewfinder")
        }
    }
}

/// Rote Plakette mit weißem Punkt und Laufzeit, als farbiges (nicht Template-)Bild.
enum RecordingBadge {
    static func image(text: String, showsText: Bool) -> NSImage {
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let size = NSSize(width: ceil(textSize.width) + 9 + 8 + 6 + 9, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 1, green: 59 / 255, blue: 48 / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 9, y: (rect.height - 8) / 2, width: 8, height: 8)).fill()
            if showsText {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                let height = (text as NSString).size(withAttributes: attributes).height
                (text as NSString).draw(at: NSPoint(x: 9 + 8 + 6, y: (rect.height - height) / 2),
                                        withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static var font: NSFont {
        .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    }
}
