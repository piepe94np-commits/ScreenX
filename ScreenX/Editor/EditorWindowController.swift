import AppKit
import Observation
import ScreenXCore
import SwiftUI

/// Ein Editor-Fenster. Offene Controller werden in `controllers` gehalten, bis ihr Fenster schließt.
/// Solange ein Editor offen ist, erscheint ScreenX im Dock und im Programmwechsler, mit eigener Menüleiste.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private static var controllers: Set<EditorWindowController> = []
    private static let defaultSize = NSSize(width: 1280, height: 800)
    private static let minimumSize = NSSize(width: 900, height: 600)

    let viewModel: EditorViewModel
    private let undoStack = UndoManager()
    private var undoObservers: [any NSObjectProtocol] = []

    /// Einstellungen für Fenster, die ohne eigene geöffnet werden (z. B. über „Öffnen …“);
    /// der `AppCoordinator` setzt hier seine Einstellungen.
    static var settingsSource: Binding<AppSettings>?
    /// Ersatz ohne `settingsSource`: liest und sichert direkt über den `SettingsStore`.
    private static let storedSettings = Bindable(StoredSettings()).value
    /// Öffnet das Einstellungsfenster („Einstellungen …“ im Editor-Menü); setzt der `AppCoordinator`.
    static var settingsOpener: (() -> Void)?

    /// Offene Editoren mit ungesicherten Änderungen.
    static var dirtyEditors: [EditorWindowController] {
        controllers.filter { $0.viewModel.isDirty }
    }

    /// `settings` steuert Inspektor, Export und Werkzeugleiste dieses Fensters.
    static func open(_ vm: EditorViewModel, settings: Binding<AppSettings>? = nil) {
        let source = settings ?? settingsSource ?? storedSettings
        let controller = EditorWindowController(viewModel: vm, settings: source)
        controllers.insert(controller)
        NSApp.setActivationPolicy(.regular)
        EditorMenu.install()
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// Holt das Fenster mit dieser Datei nach vorn. `false`, wenn keines offen ist.
    static func focus(fileURL: URL) -> Bool {
        let target = fileURL.standardizedFileURL
        guard let controller = controllers.first(where: { $0.viewModel.fileURL?.standardizedFileURL == target })
        else { return false }
        controller.showWindow(nil)
        NSApp.activate()
        return true
    }

    private init(viewModel: EditorViewModel, settings: Binding<AppSettings>) {
        self.viewModel = viewModel
        viewModel.settingsProvider = { settings.wrappedValue }
        let hosting = NSHostingController(rootView: EditorView(vm: viewModel, settings: settings))
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = Self.minimumSize
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        viewModel.undoManager = undoStack
        observeUndo()
        observeViewModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Beobachtung

    /// Titel, Dateisymbol und Änderungspunkt folgen dem ViewModel.
    private func observeViewModel() {
        withObservationTracking {
            window?.title = viewModel.title
            window?.representedURL = viewModel.fileURL
            window?.isDocumentEdited = viewModel.isDirty
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeViewModel() }
        }
    }

    private func observeUndo() {
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
        ]
        undoObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: undoStack, queue: .main) {
                [weak viewModel] _ in
                MainActor.assumeIsolated { viewModel?.refreshUndoState() }
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        undoStack
    }

    func windowDidBecomeKey(_ notification: Notification) {
        EditorMenu.install()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard viewModel.isDirty else { return true }
        // Die Abfrage läuft schon (z. B. zweites ⌘W): kein zweites Blatt stapeln.
        guard sender.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Änderungen sichern?")
        alert.informativeText = String(localized: "Ohne Sichern gehen die Änderungen verloren.")
        alert.addButton(withTitle: String(localized: "Sichern"))
        let discard = alert.addButton(withTitle: String(localized: "Nicht sichern"))
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: String(localized: "Abbrechen"))
        cancel.keyEquivalent = "\u{1b}"
        Task { [weak self] in
            let response = await alert.beginSheetModal(for: sender)
            self?.finishClose(response)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.tearDown()
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        undoObservers = []
        undoStack.removeAllActions()
        Self.controllers.remove(self)
        if Self.controllers.isEmpty {
            EditorMenu.uninstall()
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func finishClose(_ response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn:
            // Abgebrochener oder fehlgeschlagener Sicherungsversuch lässt das Fenster offen.
            if viewModel.saveProject() { window?.close() }
        case .alertSecondButtonReturn:
            window?.close()
        default:
            break
        }
    }

    // MARK: - Menübefehle (über die Responder-Kette)

    @objc func showSettings(_ sender: Any?) { Self.settingsOpener?() }
    @objc func openProject(_ sender: Any?) { viewModel.openProject() }
    @objc func saveProject(_ sender: Any?) { viewModel.saveProject() }
    @objc func saveProjectAs(_ sender: Any?) { viewModel.saveProject(choosingLocation: true) }
    @objc func exportImageAs(_ sender: Any?) { viewModel.exportAs(settings: viewModel.settingsProvider()) }
    // Eigene Selektoren der Menüpunkte: Kein AppKit- oder SwiftUI-Responder kennt sie, also erreichen sie
    // sicher diesen Controller (Fenster-Delegate), der offene Farbänderungen vor Undo/Redo abschließt.
    @objc func editorUndo(_ sender: Any?) { viewModel.undo() }
    @objc func editorRedo(_ sender: Any?) { viewModel.redo() }

    /// Kopiert das gerenderte Bild; ist in einem Textfeld Text markiert, wird dieser kopiert.
    @objc func editorCopy(_ sender: Any?) {
        if let text = window?.firstResponder as? NSText, text.selectedRange().length > 0 {
            text.copy(sender)
        } else {
            viewModel.copy()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveProject(_:)), #selector(saveProjectAs(_:)):
            return !viewModel.isReadOnly
        case #selector(editorUndo(_:)):
            menuItem.title = undoStack.undoMenuItemTitle
            return undoStack.canUndo || viewModel.hasPendingEdit
        case #selector(editorRedo(_:)):
            menuItem.title = undoStack.redoMenuItemTitle
            return undoStack.canRedo
        default:
            return true
        }
    }
}

/// Einstellungen direkt aus dem `SettingsStore`, wenn kein `AppCoordinator` sie bereitstellt.
/// Jede Änderung wird unter demselben Schlüssel („settings.v1“) gesichert.
@MainActor
@Observable
private final class StoredSettings {
    private let store: SettingsStore
    private var stored: AppSettings

    var value: AppSettings {
        get { stored }
        set {
            guard newValue != stored else { return }
            stored = newValue
            store.save(newValue)
        }
    }

    init(store: SettingsStore = SettingsStore(defaults: .standard)) {
        self.store = store
        stored = store.load()
    }
}
