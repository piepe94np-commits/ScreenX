import AppKit
import ScreenXCore
import SwiftUI

/// Zeigt das Kürzel eines Aufnahmemodus. Ein Klick nimmt das nächste Kürzel auf
/// (mindestens einer von ⌘⌥⌃), Esc bricht ab, der Löschen-Button entfernt das Kürzel.
struct HotkeyRecorderView: View {
    private static let escapeKeyCode: UInt16 = 53

    let coordinator: AppCoordinator
    let mode: CaptureMode

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        let combo = coordinator.settings.hotkeys[mode]
        let error = coordinator.hotkeyErrors[mode]
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if isRecording { stopRecording() } else { startRecording() }
                } label: {
                    Text(label(for: combo))
                        .foregroundStyle(error == nil || isRecording ? Color.primary : Color.red)
                        .frame(minWidth: 120)
                }

                Button {
                    stopRecording()
                    coordinator.setHotkey(nil, for: mode)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(String(localized: "Kürzel entfernen"))
                .disabled(combo == nil)
            }

            if let error, !isRecording {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func label(for combo: KeyCombo?) -> String {
        if isRecording { return String(localized: "Kürzel drücken …") }
        return combo?.displayString ?? String(localized: "Kein Kürzel")
    }

    // MARK: - Aufnahme

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        // Globale Kürzel abmelden, damit auch das aktuelle Kürzel erneut aufgenommen werden kann.
        coordinator.suspendHotkeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard isRecording else { return }
        isRecording = false
        coordinator.resumeHotkeys()
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            stopRecording()
            return
        }
        let modifiers = Self.modifiers(from: event.modifierFlags)
        // Shift allein genügt nicht.
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else {
            NSSound.beep()
            return
        }
        stopRecording()
        coordinator.setHotkey(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers), for: mode)
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}
