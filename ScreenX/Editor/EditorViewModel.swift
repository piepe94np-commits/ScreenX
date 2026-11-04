import AppKit
import ImageIO
import Observation
import ScreenXCore

enum EditorError: Error, LocalizedError {
    case unreadableImage
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: String(localized: "Das Bild konnte nicht gelesen werden.")
        case .renderFailed: String(localized: "Das Bild konnte nicht erzeugt werden.")
        }
    }
}

/// Zustand eines Editor-Fensters: Dokument, Undo und die Vorschau der Arbeitsfläche.
/// Das Modell ändert sich nur über `apply` bzw. `applyLive`.
@MainActor
@Observable
final class EditorViewModel {
    /// Alles, was ein Undo-Schritt wiederherstellt.
    private struct Snapshot: Sendable {
        var model: DocumentModel
        var backgroundImage: CGImage?
        var backgroundData: Data?
        var backgroundExtension: String?
    }

    private static let debounce: Duration = .milliseconds(16)

    private(set) var model: DocumentModel
    let original: CGImage
    private(set) var backgroundImage: CGImage?
    private(set) var backgroundData: Data?
    private(set) var backgroundExtension: String?
    var fileURL: URL?
    /// Mit einer neueren Version erstellt: nur ansehen, nicht ändern oder sichern.
    let isReadOnly: Bool
    var isDirty = false
    private(set) var preview: CGImage?
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// Kurze Rückmeldung wie „Kopiert“, verschwindet nach kurzer Zeit.
    private(set) var notice: String?

    @ObservationIgnored var undoManager: UndoManager? {
        didSet { refreshUndoState() }
    }
    /// Quelle der Einstellungen; das Editor-Fenster verbindet sie mit den Einstellungen des Inspektors.
    @ObservationIgnored var settingsProvider: () -> AppSettings
    /// Zeitpunkt der Aufnahme bzw. des Öffnens, für vorgeschlagene Dateinamen.
    @ObservationIgnored let createdAt: Date
    /// Ordner der zuletzt herausgezogenen Datei; wird beim nächsten Ziehen und beim Schließen entfernt.
    @ObservationIgnored var dragFolder: URL?

    @ObservationIgnored private var continuousStart: Snapshot?
    /// Name eines offenen, zeitgesteuerten Schritts (z. B. aus dem Farbfenster), sonst `nil`.
    @ObservationIgnored private var pendingEditName: String?
    @ObservationIgnored private var previewMaxPixelSize: CGSize?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var shownGeneration = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(capture: Capture, style: Style, settings: @escaping () -> AppSettings) {
        let info = OriginalInfo(
            pixelWidth: capture.image.width, pixelHeight: capture.image.height,
            scale: Double(capture.scale), mode: capture.mode, windowTitle: capture.windowTitle)
        model = DocumentModel(original: info, style: style)
        original = capture.image
        isReadOnly = false
        settingsProvider = settings
        createdAt = capture.date
    }

    init(loaded: LoadedDocument, fileURL: URL, settings: @escaping () -> AppSettings) {
        model = loaded.model
        original = loaded.original
        backgroundImage = loaded.backgroundImage
        backgroundData = loaded.backgroundData
        if case .image(let file) = loaded.model.style.background {
            backgroundExtension = (file as NSString).pathExtension
        }
        self.fileURL = fileURL
        isReadOnly = loaded.isReadOnly
        settingsProvider = settings
        createdAt = Date()
    }

    // MARK: - Abgeleitete Werte

    var title: String {
        if let fileURL { return fileURL.deletingPathExtension().lastPathComponent }
        if let name = model.original.windowTitle, !name.isEmpty { return name }
        return String(localized: "Unbenannt")
    }

    var captureScale: CGFloat {
        model.original.scale > 0 ? CGFloat(model.original.scale) : 1
    }

    /// Größe der Arbeitsfläche in Pixeln des Originals.
    var canvasSize: CGSize {
        let content = model.crop?.size ?? CGSize(width: original.width, height: original.height)
        return CanvasLayout.compute(contentSize: content, style: model.style).canvasSize
    }

    private var renderInput: RenderInput {
        RenderInput(original: original, crop: model.crop, style: model.style, backgroundImage: backgroundImage)
    }

    private var snapshot: Snapshot {
        Snapshot(model: model, backgroundImage: backgroundImage,
                 backgroundData: backgroundData, backgroundExtension: backgroundExtension)
    }

    // MARK: - Änderungen und Undo

    func apply(_ actionName: String, _ change: (inout DocumentModel) -> Void) {
        guard !isReadOnly else { return }
        flushPendingEdit()
        let before = snapshot
        var updated = model
        change(&updated)
        guard updated != model else { return }
        model = updated
        commit(from: before, actionName)
    }

    func beginContinuousChange() {
        guard !isReadOnly else { return }
        flushPendingEdit()
        guard continuousStart == nil else { return }
        continuousStart = snapshot
    }

    /// Beginnt bzw. setzt einen Schritt fort, der kein Ende-Ereignis hat (Farbfenster).
    /// Er endet mit `flushPendingEdit()`: zeitgesteuert, vor jeder anderen Änderung und vor Undo/Redo.
    func beginPendingEdit(_ actionName: String) {
        guard !isReadOnly else { return }
        if pendingEditName == nil {
            flushPendingEdit()
            guard continuousStart == nil else { return }
            continuousStart = snapshot
        }
        pendingEditName = actionName
        refreshUndoState()
    }

    /// Schließt einen offenen Schritt aus `beginPendingEdit` als einen Undo-Schritt ab.
    func flushPendingEdit() {
        guard let name = pendingEditName else { return }
        endContinuousChange(name)
    }

    var hasPendingEdit: Bool { pendingEditName != nil }

    /// Ändert das Modell während eines Reglerzugs, ohne Undo-Schritt.
    func applyLive(_ change: (inout DocumentModel) -> Void) {
        guard !isReadOnly else { return }
        var updated = model
        change(&updated)
        guard updated != model else { return }
        model = updated
        isDirty = true
        scheduleRender()
    }

    /// Registriert genau einen Undo-Schritt für den ganzen Reglerzug (falls sich etwas geändert hat).
    func endContinuousChange(_ actionName: String) {
        guard let start = continuousStart else { return }
        continuousStart = nil
        pendingEditName = nil
        defer { refreshUndoState() }
        guard start.model != model else { return }
        registerUndo(restoring: start, actionName)
    }

    func setBackgroundImage(data: Data, ext: String) throws {
        guard !isReadOnly else { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw EditorError.unreadableImage }
        flushPendingEdit()
        let before = snapshot
        let ext = ext.lowercased()
        backgroundImage = image
        backgroundData = data
        backgroundExtension = ext
        model.style.background = .image(file: "background.\(ext)")
        commit(from: before, String(localized: "Hintergrundbild"))
    }

    func undo() {
        flushPendingEdit()
        undoManager?.undo()
    }

    func redo() {
        flushPendingEdit()
        undoManager?.redo()
    }

    func refreshUndoState() {
        canUndo = (undoManager?.canUndo ?? false) || pendingEditName != nil
        canRedo = undoManager?.canRedo ?? false
    }

    private func commit(from before: Snapshot, _ actionName: String) {
        registerUndo(restoring: before, actionName)
        isDirty = true
        scheduleRender()
    }

    private func registerUndo(restoring state: Snapshot, _ actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { vm in
            MainActor.assumeIsolated { vm.restore(state, actionName) }
        }
        undoManager.setActionName(actionName)
        refreshUndoState()
    }

    /// Stellt `state` her und registriert den Gegenschritt (Redo bzw. erneutes Undo).
    private func restore(_ state: Snapshot, _ actionName: String) {
        let current = snapshot
        model = state.model
        backgroundImage = state.backgroundImage
        backgroundData = state.backgroundData
        backgroundExtension = state.backgroundExtension
        commit(from: current, actionName)
    }

    // MARK: - Rendern

    /// Rendert die Vorschau höchstens in `maxPixelSize` (Ansichtsgröße × Backing-Scale).
    /// Es läuft höchstens ein Rendervorgang; Änderungen währenddessen werden danach nachgeholt.
    func renderPreview(maxPixelSize: CGSize) {
        guard maxPixelSize.width >= 1, maxPixelSize.height >= 1 else { return }
        previewMaxPixelSize = maxPixelSize
        scheduleRender()
    }

    func renderFull(scale: ExportScale, captureScale: CGFloat) -> CGImage? {
        Renderer.render(renderInput, outputScale: ExportScaling.factor(scale, captureScale: captureScale))
    }

    /// Beendet laufende Arbeit beim Schließen des Fensters.
    func tearDown() {
        renderTask?.cancel()
        renderTask = nil
        previewMaxPixelSize = nil
        noticeTask?.cancel()
        if let dragFolder { try? FileManager.default.removeItem(at: dragFolder) }
        dragFolder = nil
    }

    private func scheduleRender() {
        generation += 1
        guard renderTask == nil, previewMaxPixelSize != nil else { return }
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            await self?.runRenderLoop()
        }
    }

    /// Rendert abseits des Main Actors, bis das Ergebnis zum aktuellen Stand passt.
    /// Ergebnisse, die älter als die angezeigte Vorschau sind, werden verworfen.
    private func runRenderLoop() async {
        defer { renderTask = nil }
        while !Task.isCancelled, let maxSize = previewMaxPixelSize {
            let current = generation
            let input = renderInput
            let canvas = canvasSize
            guard canvas.width > 0, canvas.height > 0 else { return }
            let scale = min(1, maxSize.width / canvas.width, maxSize.height / canvas.height)
            let image = await Task.detached(priority: .userInitiated) {
                Renderer.render(input, outputScale: scale)
            }.value
            guard !Task.isCancelled else { return }
            if let image, current > shownGeneration {
                preview = image
                shownGeneration = current
            }
            if current == generation { return }
            try? await Task.sleep(for: Self.debounce)
        }
    }

    // MARK: - Rückmeldung

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
