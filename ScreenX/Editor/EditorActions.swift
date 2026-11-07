import AppKit
import os
import ScreenXCore
import UniformTypeIdentifiers

private let projectLogger = Logger(subsystem: "com.screenx.app", category: "project")

/// Aktionen des Editors: Kopieren, Sichern, Export mit Dialog, Projekt sichern und öffnen.
/// Fehler erscheinen als Hinweisfenster; das Dokument bleibt dabei offen und unverändert.
extension EditorViewModel {
    /// `com.screenx.document`; vor der Typ-Deklaration im Info.plist über die Endung bestimmt.
    static var projectType: UTType {
        UTType(ScreenXPackage.typeIdentifier)
            ?? UTType(filenameExtension: ScreenXPackage.fileExtension, conformingTo: .package)
            ?? .package
    }

    /// Pixel je Punkt der exportierten Datei (für DPI und Zwischenablage).
    func exportPixelScale(_ settings: AppSettings) -> CGFloat {
        captureScale * ExportScaling.factor(settings.exportScale, captureScale: captureScale)
    }

    /// Pixelgröße der exportierten Datei.
    func exportPixelSize(_ settings: AppSettings) -> (width: Int, height: Int) {
        let factor = ExportScaling.factor(settings.exportScale, captureScale: captureScale)
        let canvas = canvasSize
        return (max(1, Int((canvas.width * factor).rounded())), max(1, Int((canvas.height * factor).rounded())))
    }

    func copy() {
        let settings = settingsProvider()
        do {
            Clipboard.copy(try exportImage(settings), scale: exportPixelScale(settings))
            showNotice(String(localized: "Kopiert"))
        } catch {
            Self.present(error)
        }
    }

    /// „Sichern“: schreibt das Bild ohne Dialog in den Speicherort.
    func quickSave(settings: AppSettings) {
        do {
            _ = try ImageExporter.write(
                try exportImage(settings), scale: exportPixelScale(settings), to: settings.saveDirectory,
                date: Date(), format: settings.exportFormat, jpegQuality: settings.jpegQuality)
            showNotice(String(localized: "Gesichert"))
        } catch {
            Self.present(error)
        }
    }

    /// „Sichern unter …“: Export mit Dialog und Formatauswahl.
    func exportAs(settings: AppSettings) {
        let panel = NSSavePanel()
        panel.directoryURL = settings.saveDirectory
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ImageExporter.fileName(date: Date(), format: settings.exportFormat)
        let chooser = FormatChooser(panel: panel, format: settings.exportFormat)
        panel.accessoryView = chooser.view
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ImageExporter.data(
                for: try exportImage(settings), scale: exportPixelScale(settings),
                format: chooser.format, jpegQuality: settings.jpegQuality)
            try data.write(to: url, options: .atomic)
            showNotice(String(localized: "Gesichert"))
        } catch {
            Self.present(error)
        }
    }

    /// Sichert das Projekt (`.screenx`). Ohne Dateiort, oder mit `choosingLocation`
    /// („Projekt sichern unter …“), wird zuerst nach dem Ort gefragt. Schlägt das Schreiben fehl
    /// (z. B. weil der Ort schreibgeschützt ist), erscheint die Meldung und danach der Sichern-Dialog,
    /// damit das Projekt an einem anderen Ort gesichert werden kann. Offene Bearbeitungen (Text, Mauszug,
    /// Farbschritt) werden vorher abgeschlossen.
    /// `false`, wenn abgebrochen wurde oder das Sichern fehlschlug.
    @discardableResult
    func saveProject(choosingLocation: Bool = false) -> Bool {
        guard !isReadOnly else { return false }
        // Gesichert wird ein abgeschlossener Stand: sonst wäre das Fenster danach „unverändert“, obwohl
        // Esc bzw. ein Abbruch das Modell noch gegenüber der Datei ändern würde.
        finishOpenEdits()
        var target = choosingLocation ? nil : fileURL
        while true {
            guard let url = target ?? chooseProjectLocation() else { return false }
            do {
                try writeProject(to: url)
                fileURL = url
                isDirty = false
                return true
            } catch {
                Self.present(error)
                target = nil
            }
        }
    }

    private func writeProject(to url: URL) throws {
        var usesImage = false
        if case .image = model.style.background { usesImage = true }
        let custom = customTemplateForSaving()
        try ScreenXPackage.write(
            model: model, original: original, backgroundData: usesImage ? backgroundData : nil,
            backgroundExtension: backgroundExtension,
            customTemplate: custom.template, customFrameData: custom.frameData, to: url)
    }

    /// Eigene Vorlage, die ins Paket kommt: die aufgelöste samt ihren schon gelesenen Bilddaten (aus dem
    /// geöffneten Paket bzw. dem Vorlagenordner); der Vorlagenordner wird nur gefragt, wenn nichts aufgelöst ist.
    private func customTemplateForSaving() -> (template: DeviceTemplate?, frameData: Data?) {
        guard let id = model.template?.templateID, TemplateCatalog.builtin(id: id) == nil else { return (nil, nil) }
        let result: (template: DeviceTemplate?, frameData: Data?)
        if let resolvedTemplate, resolvedTemplate.id == id {
            result = (resolvedTemplate, resolvedCustomFrameData)
        } else if let template = CustomTemplateStore.shared.template(id: id) {
            result = (template, CustomTemplateStore.shared.imageData(for: template))
        } else {
            result = (nil, nil)
        }
        if result.template != nil, result.frameData == nil {
            projectLogger.error("Custom template \(id, privacy: .public) is saved without its frame image")
        }
        return result
    }

    /// Sichern-Dialog für das Projekt; `nil` bei Abbruch.
    private func chooseProjectLocation() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.directoryURL = settingsProvider().saveDirectory
        panel.canCreateDirectories = true
        if let fileURL {
            panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent
        } else {
            panel.nameFieldStringValue = Self.baseName(ImageExporter.fileName(date: createdAt, format: .png))
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func openProject() {
        Self.openProject(settings: settingsProvider)
    }

    static func openProject(settings: @escaping () -> AppSettings) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [projectType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            open(url: url, settings: settings)
        }
    }

    /// Öffnet `url` in einem Editor-Fenster oder holt ein bereits offenes nach vorn.
    static func open(url: URL, settings: @escaping () -> AppSettings) {
        if EditorWindowController.focus(fileURL: url) { return }
        do {
            let loaded = try ScreenXPackage.read(from: url, store: .shared)
            EditorWindowController.open(EditorViewModel(loaded: loaded, fileURL: url, settings: settings))
        } catch {
            present(error)
        }
    }

    /// Rendert und schreibt die Datei, die beim Herausziehen aus der Arbeitsfläche übergeben wird.
    func makeDragFile() throws -> URL {
        let settings = settingsProvider()
        let data = try ImageExporter.data(
            for: try exportImage(settings), scale: exportPixelScale(settings),
            format: settings.exportFormat, jpegQuality: settings.jpegQuality)
        if let dragFolder { try? FileManager.default.removeItem(at: dragFolder) }
        let folder = DragFile.makeFolder()
        dragFolder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ImageExporter.fileName(date: Date(), format: settings.exportFormat))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func present(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.localizedDescription
        alert.runModal()
    }

    private func exportImage(_ settings: AppSettings) throws -> CGImage {
        guard let image = renderFull(scale: settings.exportScale, captureScale: captureScale) else {
            throw EditorError.renderFailed
        }
        return image
    }

    /// Entfernt eine bekannte Bild-Endung (und nur diese).
    fileprivate static func baseName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg"].contains(ext) ? (name as NSString).deletingPathExtension : name
    }
}

/// Formatauswahl (PNG/JPEG) unter dem Sichern-Dialog; passt Typ und Endung an.
@MainActor
private final class FormatChooser: NSObject {
    private(set) var format: ExportFormat
    let view: NSView
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(panel: NSSavePanel, format: ExportFormat) {
        self.panel = panel
        self.format = format
        popup.addItems(withTitles: ["PNG", "JPEG"])
        popup.selectItem(at: format == .png ? 0 : 1)
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(formatChanged(_:))
        applyFormat()
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        format = sender.indexOfSelectedItem == 0 ? .png : .jpeg
        applyFormat()
    }

    private func applyFormat() {
        guard let panel else { return }
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.nameFieldStringValue = EditorViewModel.baseName(panel.nameFieldStringValue) + "." + format.fileExtension
    }
}
