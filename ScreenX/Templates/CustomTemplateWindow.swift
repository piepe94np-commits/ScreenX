import AppKit
import ImageIO
import Observation
import OSLog
import ScreenXCore
import SwiftUI
import UniformTypeIdentifiers

/// Fenster zum Anlegen einer eigenen Vorlage: Bild (PNG/JPEG/HEIC/TIFF oder PDF) laden, die vier Ecken des
/// Displays anklicken, benennen und sichern. Es gibt höchstens ein Fenster; ein weiterer Aufruf holt es nach
/// vorn und sichert danach für den zuletzt aufrufenden Editor.
@MainActor
enum CustomTemplateWindow {
    private static var window: NSWindow?
    private static var creator: CustomTemplateCreator?
    private static var closeObserver: (any NSObjectProtocol)?

    /// `onSave` erhält die neu gesicherte Vorlage (nach `store.add` und `customTemplatesDidChange`).
    static func show(store: CustomTemplateStore, onSave: @escaping @MainActor (DeviceTemplate) -> Void) {
        if let window, let creator {
            creator.onSave = onSave
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let creator = CustomTemplateCreator(store: store, onSave: onSave)
        let hosting = NSHostingController(rootView: QuadPickerView(creator: creator))
        hosting.sizingOptions = []
        let window = CustomTemplatePanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 760, height: 620))
        window.contentMinSize = NSSize(width: 560, height: 440)
        window.title = String(localized: "Eigene Vorlage anlegen")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.center()
        creator.close = { [weak window] in window?.close() }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CustomTemplateWindow.didClose() }
        }
        self.window = window
        self.creator = creator
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func didClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
        creator = nil
    }
}

/// Das Fenster nimmt die eigenen Befehle des Editor-Menüs an (Kopieren, Widerrufen), damit sie im Namensfeld
/// funktionieren; sonst erreichen sie nur Editor-Fenster.
private final class CustomTemplatePanelWindow: NSWindow {
    @objc func editorCopy(_ sender: Any?) {
        (firstResponder as? NSText)?.copy(sender)
    }

    @objc func editorUndo(_ sender: Any?) {
        undoManager?.undo()
    }

    @objc func editorRedo(_ sender: Any?) {
        undoManager?.redo()
    }
}

/// Zustand des Fensters: geladenes Bild, angeklickte Ecken (Pixel des Bildes, Ursprung oben links) und Name.
@MainActor
@Observable
final class CustomTemplateCreator {
    /// Bild, wie es gesichert wird (ein PDF ist schon als PNG gerastert).
    struct LoadedImage {
        let image: CGImage
        let data: Data
        let fileExtension: String

        var size: CGSize { CGSize(width: image.width, height: image.height) }
    }

    private static let logger = Logger(subsystem: "com.screenx.app", category: "templates")
    /// Dateitypen, die das Fenster annimmt (Bilder wie der Vorlagenordner, dazu PDF).
    static let acceptedExtensions = CustomTemplateStore.allowedImageExtensions.union(["pdf"])

    private(set) var loaded: LoadedImage?
    /// Ecken in Klickreihenfolge; höchstens vier, immer innerhalb des Bildes.
    var points: [CGPoint] = []
    var name = ""
    /// Fehler für den Hinweisdialog.
    var errorMessage: String?

    @ObservationIgnored let store: CustomTemplateStore
    @ObservationIgnored var onSave: @MainActor (DeviceTemplate) -> Void
    @ObservationIgnored var close: (@MainActor () -> Void)?

    init(store: CustomTemplateStore, onSave: @escaping @MainActor (DeviceTemplate) -> Void) {
        self.store = store
        self.onSave = onSave
    }

    var canSave: Bool {
        loaded != nil && points.count == 4 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Lädt eine Datei; ein PDF wird mit 2× gerastert. Fehler erscheinen als Hinweis, das alte Bild bleibt.
    func load(url: URL) {
        do {
            let ext = url.pathExtension.lowercased()
            guard Self.acceptedExtensions.contains(ext) else {
                throw TemplateError.unsupportedImageType(url.pathExtension)
            }
            var data = try Data(contentsOf: url)
            var fileExtension = ext
            if ext == "pdf" {
                data = try TemplateImageImport.rasterizeFirstPage(pdfData: data, scale: 2)
                fileExtension = "png"
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw TemplateError.unreadableImage }
            guard CGFloat(image.width) <= CustomTemplateStore.maxFrameSide,
                  CGFloat(image.height) <= CustomTemplateStore.maxFrameSide
            else { throw TemplateError.imageTooLarge }
            loaded = LoadedImage(image: image, data: data, fileExtension: fileExtension)
            points = []
            name = url.deletingPathExtension().lastPathComponent
        } catch {
            Self.logger.error("Vorlagenbild nicht geladen: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    /// „Datei wählen …“
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func reset() {
        points = []
    }

    /// Sichert die Vorlage im Vorlagenordner, meldet sie (`customTemplatesDidChange`), übergibt sie an
    /// `onSave` und schließt das Fenster. Fehler erscheinen als Hinweis.
    func save() {
        guard canSave, let loaded else { return }
        do {
            let template = try store.add(name: name, imageData: loaded.data, imageExtension: loaded.fileExtension,
                                         quad: QuadPicking.orderedClockwise(points))
            NotificationCenter.default.post(name: .customTemplatesDidChange, object: nil)
            onSave(template)
            close?()
        } catch {
            Self.logger.error("Vorlage nicht gesichert: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }
}
