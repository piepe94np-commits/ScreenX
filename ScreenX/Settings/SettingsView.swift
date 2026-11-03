import AppKit
import ScreenXCore
import SwiftUI

/// Einstellungsfenster (SwiftUI `Settings`-Scene).
struct SettingsView: View {
    let coordinator: AppCoordinator

    var body: some View {
        TabView {
            Tab(String(localized: "Allgemein"), systemImage: "gearshape") {
                GeneralSettingsView(coordinator: coordinator)
            }
        }
        .frame(width: 520)
    }
}

/// Reiter „Allgemein“. Die Option „Nach der Aufnahme: Editor öffnen“ folgt mit M2.
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
                LabeledContent(String(localized: "Schnellzugriff-Dauer")) {
                    HStack {
                        Slider(value: $coordinator.settings.quickAccessDuration, in: 3...30, step: 1)
                        Text(String(localized: "\(Int(coordinator.settings.quickAccessDuration)) s"))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                Toggle(String(localized: "Fensterschatten aufnehmen"), isOn: $coordinator.settings.windowShadow)
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
