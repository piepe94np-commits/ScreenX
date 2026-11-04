import AppKit
import ScreenXCore
import SwiftUI

/// Reiter „Export“: Format, Skalierung, Speicherort, Dateiname und Export-Aktionen.
/// Änderungen gehen direkt in die `AppSettings`.
struct ExportSection: View {
    let vm: EditorViewModel
    @Binding var settings: AppSettings

    var body: some View {
        InspectorGroup(title: String(localized: "Format")) {
            Picker(String(localized: "Format"), selection: $settings.exportFormat) {
                Text(verbatim: "PNG").tag(ExportFormat.png)
                Text(verbatim: "JPEG").tag(ExportFormat.jpeg)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Text("Qualität")
                    .frame(width: 78, alignment: .leading)
                Slider(value: qualityPercent, in: 0...100, step: 1)
                Text(Int(qualityPercent.wrappedValue), format: IntegerFormatStyle<Int>())
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            .disabled(settings.exportFormat != .jpeg)
        }

        InspectorGroup(title: String(localized: "Skalierung")) {
            Picker(String(localized: "Skalierung"), selection: $settings.exportScale) {
                Text("Original").tag(ExportScale.original)
                Text(verbatim: "1×").tag(ExportScale.x1)
                Text(verbatim: "2×").tag(ExportScale.x2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let size = vm.exportPixelSize(settings)
            Text(String(localized: "\(size.width) × \(size.height) px"))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }

        InspectorGroup(title: String(localized: "Speicherort")) {
            HStack(spacing: 8) {
                Text(settings.saveDirectory.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(settings.saveDirectory.path(percentEncoded: false))
                Spacer(minLength: 0)
                Button(String(localized: "Ändern …"), action: chooseDirectory)
            }

            LabeledContent(String(localized: "Dateiname")) {
                Text(ImageExporter.fileName(date: Date(), format: settings.exportFormat))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }

        HStack(spacing: 8) {
            Button(String(localized: "Kopieren")) { vm.copy() }
            Button(String(localized: "Sichern unter …")) { vm.exportAs(settings: settings) }
            Spacer(minLength: 0)
            Button(String(localized: "Sichern")) { vm.quickSave(settings: settings) }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    /// JPEG-Qualität als 0–100 (gespeichert als 0–1).
    private var qualityPercent: Binding<Double> {
        Binding(
            get: { (settings.jpegQuality * 100).rounded() },
            set: { settings.jpegQuality = min(1, max(0, $0 / 100)) })
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveDirectory
        panel.prompt = String(localized: "Auswählen")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveDirectory = url
    }
}
