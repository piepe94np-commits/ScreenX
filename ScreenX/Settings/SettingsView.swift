import AppKit
import ScreenXCore
import SwiftUI

/// Reiter des Einstellungsfensters.
enum SettingsTab: Hashable {
    case general, video
}

/// Gewählter Reiter, auch von außen setzbar: Vor `showSettings()` z. B.
/// `SettingsNavigation.shared.tab = .video` öffnet die Einstellungen im Reiter „Video“.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var tab: SettingsTab = .general
}

/// Einstellungsfenster (SwiftUI `Settings`-Scene).
struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        TabView(selection: Bindable(SettingsNavigation.shared).tab) {
            Tab(String(localized: "Allgemein"), systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView(coordinator: coordinator)
                    .frame(width: 520)
            }
            Tab(String(localized: "Video"), systemImage: "video", value: SettingsTab.video) {
                VideoSettingsView(coordinator: coordinator)
                    .frame(width: 760, height: 560)
            }
        }
        // Ein Screenshot-Kürzel, das dem Video-Kürzel gleicht, nimmt es diesem weg (wie zwischen den Modi).
        .onChange(of: coordinator.settings.hotkeys) { _, hotkeys in
            if let video = coordinator.settings.videoHotkey, hotkeys.values.contains(video) {
                coordinator.settings.videoHotkey = nil
            }
        }
    }
}

/// Reiter „Allgemein“.
private struct GeneralSettingsView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section(String(localized: "Tastenkürzel")) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    LabeledContent(mode.title) {
                        HotkeyRecorderView(coordinator: coordinator, mode: mode)
                    }
                }
            }

            Section(String(localized: "Sichern")) {
                LabeledContent(String(localized: "Speicherort")) {
                    HStack {
                        Text(coordinator.settings.saveDirectory.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Auswählen …")) { chooseDirectory() }
                    }
                }

                Picker(String(localized: "Format"), selection: $coordinator.settings.exportFormat) {
                    Text(verbatim: "PNG").tag(ExportFormat.png)
                    Text(verbatim: "JPEG").tag(ExportFormat.jpeg)
                }
                .pickerStyle(.segmented)

                LabeledContent(String(localized: "JPEG-Qualität")) {
                    HStack {
                        Slider(value: $coordinator.settings.jpegQuality, in: 0.1...1, step: 0.05)
                        Text(coordinator.settings.jpegQuality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(coordinator.settings.exportFormat != .jpeg)
            }

            Section(String(localized: "Aufnahme")) {
                Picker(String(localized: "Nach der Aufnahme"), selection: $coordinator.settings.afterCapture) {
                    Text(String(localized: "Schnellzugriff zeigen")).tag(AfterCaptureAction.quickAccess)
                    Text(String(localized: "Editor öffnen")).tag(AfterCaptureAction.openEditor)
                }

                LabeledContent(String(localized: "Schnellzugriff-Dauer")) {
                    HStack {
                        Slider(value: $coordinator.settings.quickAccessDuration, in: 3...30, step: 1)
                        Text(String(localized: "\(Int(coordinator.settings.quickAccessDuration)) s"))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                Toggle(String(localized: "Fensterschatten aufnehmen"), isOn: $coordinator.settings.windowShadow)

                Toggle(String(localized: "Zuletzt genutzten Stil anwenden"), isOn: $coordinator.settings.applyLastStyle)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = coordinator.settings.saveDirectory
        panel.prompt = String(localized: "Auswählen")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.settings.saveDirectory = url
    }
}
