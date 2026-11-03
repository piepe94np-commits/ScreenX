import ScreenXCore
import SwiftUI

/// Zeigt das Kürzel eines Aufnahmemodus. Ein Klick nimmt das nächste Kürzel auf
/// (mindestens einer von ⌘⌥⌃), Esc bricht ab, der Löschen-Button entfernt das Kürzel.
/// Die Aufnahme selbst (ein einziger lokaler Monitor) liegt im `AppCoordinator`.
struct HotkeyRecorderView: View {
    let coordinator: AppCoordinator
    let mode: CaptureMode

    private var isRecording: Bool { coordinator.recordingMode == mode }

    var body: some View {
        let combo = coordinator.settings.hotkeys[mode]
        let error = coordinator.hotkeyErrors[mode]
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if isRecording { coordinator.stopRecording() } else { coordinator.startRecording(mode) }
                } label: {
                    Text(label(for: combo))
                        .foregroundStyle(error == nil || isRecording ? Color.primary : Color.red)
                        .frame(minWidth: 120)
                }

                Button {
                    if isRecording { coordinator.stopRecording() }
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
        .onDisappear {
            if isRecording { coordinator.stopRecording() }
        }
    }

    private func label(for combo: KeyCombo?) -> String {
        if isRecording { return String(localized: "Kürzel drücken …") }
        return combo?.displayString ?? String(localized: "Kein Kürzel")
    }
}
