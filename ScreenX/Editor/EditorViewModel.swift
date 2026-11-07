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

    private(set) var model: DocumentModel {
        didSet {
            if model.template?.templateID != oldValue.template?.templateID { resolveTemplate() }
            if model.template != oldValue.template || model.style.tilt != oldValue.style.tilt {
                enforceAnnotationLock()
            }
        }
    }
    let original: CGImage
    private(set) var backgroundImage: CGImage?
    private(set) var backgroundData: Data?
    private(set) var backgroundExtension: String?
    /// Eigene Vorlage aus dem geöffneten Paket samt Bilddaten; sie wird beim Sichern wieder eingebettet,
    /// auch wenn sie im Vorlagenordner inzwischen fehlt.
    let loadedCustomTemplate: DeviceTemplate?
    let loadedCustomFrameData: Data?
    private let loadedCustomFrameImage: CGImage?
    /// Die Vorlage von `model.template`: mitgeliefert, aus dem Paket oder aus dem Vorlagenordner.
    /// `nil` ohne Vorlage und wenn sie fehlt (`isTemplateMissing`); dann zeigt die Fläche das Bild ohne Gerät,
    /// `model.template` bleibt erhalten.
    private(set) var resolvedTemplate: DeviceTemplate?
    /// Rahmenbild von `resolvedTemplate`, wenn es eine eigene Vorlage ist.
    private(set) var customFrameImage: CGImage?
    /// Bilddaten von `resolvedTemplate`, wenn es eine eigene Vorlage ist (`customFrameImage` ist daraus
    /// dekodiert). Beim Sichern werden sie eingebettet, ohne den Vorlagenordner erneut zu lesen, auch wenn die
    /// Datei dort inzwischen gelöscht wurde.
    @ObservationIgnored private(set) var resolvedCustomFrameData: Data?
    /// Öffnet das Fenster zum Anlegen einer eigenen Vorlage; `nil` blendet „+ Eigene Vorlage …“ aus.
    var onCreateCustomTemplate: (@MainActor () -> Void)?
    var fileURL: URL?
    /// Mit einer neueren Version erstellt: nur ansehen, nicht ändern oder sichern.
    let isReadOnly: Bool
    var isDirty = false
    private(set) var preview: CGImage?
    /// Das letzte Rendern des aktuellen Stands ist fehlgeschlagen (statt endlos zu laden, zeigt die Fläche
    /// einen Fehler).
    private(set) var renderFailed = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// Kurze Rückmeldung wie „Kopiert“, verschwindet nach kurzer Zeit.
    private(set) var notice: String?
    /// Aktives Werkzeug dieses Fensters. Ein Wechsel übernimmt eine offene Textbearbeitung;
    /// mit dem Zuschnitt-Werkzeug zeigt die Fläche das ganze Original.
    var tool: EditorTool = .select {
        didSet { toolDidChange(from: oldValue) }
    }
    /// IDs der ausgewählten Anmerkungen. Die Auswahl ist kein Teil des Dokuments und kein Undo-Schritt;
    /// IDs, die es nach Undo/Redo nicht mehr gibt bzw. die der Zuschnitt ganz verdeckt, fallen heraus.
    var selection: Set<UUID> = []
    /// Text- bzw. Notiz-Anmerkung, deren Text gerade über der Arbeitsfläche bearbeitet wird
    /// (`beginTextEditing` … `endTextEditing`). Die Vorschau zeichnet ihren Text so lange nicht,
    /// das Textfeld darüber zeigt ihn.
    private(set) var editingTextID: UUID? {
        didSet { if editingTextID != oldValue { scheduleRender() } }
    }
    /// Rahmen des Zuschnitt-Werkzeugs in Pixeln des Originals, nur solange es aktiv ist.
    /// Erst „Fertig“ bzw. ↩ übernimmt ihn als `crop`.
    var cropDraft: CGRect?

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
    /// Die bearbeitete Anmerkung entstand gerade erst (ihr Hinzufügen gehört zum Schritt der Bearbeitung).
    @ObservationIgnored private var textEditIsNew = false
    /// Rahmenhöhe zu Beginn der Bearbeitung; der Rahmen wächst mit dem Text, aber nie darunter.
    @ObservationIgnored private var textEditStartHeight: CGFloat = 0
    /// `isDirty` zu Beginn des offenen Schritts: bleibt das Modell unverändert, gilt er wieder.
    @ObservationIgnored private var continuousStartDirty = false
    /// Bricht einen laufenden Mauszug ab (gesetzt von der Interaktionsschicht), z. B. vor Undo/Redo.
    @ObservationIgnored var interruptInteraction: (@MainActor () -> Void)?
    /// Name eines offenen, zeitgesteuerten Schritts (z. B. aus dem Farbfenster), sonst `nil`.
    @ObservationIgnored private var pendingEditName: String?
    @ObservationIgnored private var previewMaxPixelSize: CGSize?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var shownGeneration = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Beobachtet `customTemplatesDidChange`; wird in `tearDown` entfernt.
    @ObservationIgnored private var templatesObserver: (any NSObjectProtocol)?
    /// Eigene Vorlagen, die in dieser Sitzung samt Bild aufgelöst wurden. Ein Wechsel (auch per Undo) zurück
    /// zu einer davon liest den Vorlagenordner nicht erneut; eigene Vorlagen ändern sich nie unter ihrer ID.
    @ObservationIgnored private var sessionCustomTemplates: [String: ResolvedCustomTemplate] = [:]
    /// `tearDown` lief schon (Fenster geschlossen): späte Änderungen aus der Oberfläche sind bedeutungslos.
    @ObservationIgnored private(set) var isTornDown = false

    private struct ResolvedCustomTemplate {
        let template: DeviceTemplate
        let frameData: Data?
        let frameImage: CGImage?
    }

    init(capture: Capture, style: Style, settings: @escaping () -> AppSettings) {
        let info = OriginalInfo(
            pixelWidth: capture.image.width, pixelHeight: capture.image.height,
            scale: Double(capture.scale), mode: capture.mode, windowTitle: capture.windowTitle)
        model = DocumentModel(original: info, style: style)
        original = capture.image
        loadedCustomTemplate = nil
        loadedCustomFrameData = nil
        loadedCustomFrameImage = nil
        isReadOnly = false
        settingsProvider = settings
        createdAt = capture.date
        resolveTemplate()
        observeCustomTemplates()
    }

    init(loaded: LoadedDocument, fileURL: URL, settings: @escaping () -> AppSettings) {
        model = loaded.model
        original = loaded.original
        backgroundImage = loaded.backgroundImage
        backgroundData = loaded.backgroundData
        if case .image(let file) = loaded.model.style.background {
            backgroundExtension = (file as NSString).pathExtension
        }
        loadedCustomTemplate = loaded.customTemplate
        loadedCustomFrameData = loaded.customFrameData
        loadedCustomFrameImage = loaded.customFrameImage
        self.fileURL = fileURL
        isReadOnly = loaded.isReadOnly
        settingsProvider = settings
        createdAt = Date()
        resolveTemplate()
        observeCustomTemplates()
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

    /// Aufteilung der Arbeitsfläche in Pixeln des Originals (wie beim Export, mit Vorlage und Kippen).
    var canvasLayout: CanvasLayout {
        Renderer.layout(for: layoutInput(preview: false)).canvas
    }

    /// Größe des (zugeschnittenen) Bildinhalts in Pixeln, wie er in die Vorlage kommt.
    var contentSize: CGSize {
        Renderer.contentRect(for: layoutInput(preview: false)).size
    }

    /// Größe der Arbeitsfläche in Pixeln des Originals (wie exportiert).
    var canvasSize: CGSize { canvasLayout.canvasSize }

    /// Das ganze Original in seinen Pixeln.
    var originalBounds: CGRect { CGRect(x: 0, y: 0, width: original.width, height: original.height) }

    /// Der angezeigte Zuschnitt: beim Zuschnitt-Werkzeug keiner (die Fläche zeigt das ganze Original).
    private var displayCrop: CGRect? { tool == .crop ? nil : model.crop }

    /// Die auf der angezeigten Fläche sichtbaren Anmerkungen (wie beim Rendern; mit Vorlage nur, was im
    /// Bildschirm liegt). Nur sie lassen sich treffen, auswählen und bearbeiten; ganz weggeschnittene bleiben
    /// unberührt. Ohne affine Abbildung (`isAnnotationEditable`) keine.
    var interactiveAnnotations: [Annotation] {
        guard let visible = CanvasMapping(input: layoutInput(preview: true), viewScale: 1)?.visibleRect
        else { return [] }
        return model.annotations.filter { AnnotationGeometry.isVisible($0, in: visible) }
    }

    /// Aufteilung der angezeigten Arbeitsfläche (mit `displayCrop`, Vorlage und Kippen wie die Vorschau).
    var displayLayout: CanvasLayout {
        Renderer.layout(for: layoutInput(preview: true)).canvas
    }

    /// Größe der angezeigten Arbeitsfläche in Pixeln.
    var displaySize: CGSize { displayLayout.canvasSize }

    /// Abbildung zwischen Ansichtspunkten der angezeigten Arbeitsfläche und Pixeln des Originals, durch die
    /// Vorlage hindurch. `viewScale` sind Ansichtspunkte je Pixel der Arbeitsfläche.
    /// `nil`, solange sich Anmerkungen nicht bearbeiten lassen (Kippen bzw. schräge Vorlage).
    func canvasMapping(viewScale: CGFloat) -> CanvasMapping? {
        CanvasMapping(input: layoutInput(preview: true), viewScale: viewScale)
    }

    /// Eingabe für Export (`preview == false`) bzw. Vorschau: Die Vorschau nutzt `displayCrop` und
    /// lässt den Text der gerade bearbeiteten Anmerkung weg.
    private func renderInput(preview: Bool) -> RenderInput {
        var annotations = model.annotations
        if preview, let id = editingTextID, let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index] = Self.withText(annotations[index], "", height: nil)
        }
        return layoutInput(preview: preview, annotations: annotations)
    }

    /// Die eine Quelle für Vorschau, Export und Aufteilung der Fläche. Mit dem Zuschnitt-Werkzeug zeigt die
    /// Vorschau das ganze Original ohne Vorlage und ohne Kippen.
    private func layoutInput(preview: Bool, annotations: [Annotation] = []) -> RenderInput {
        let plain = preview && tool == .crop
        var style = model.style
        if plain { style.tilt = .zero }
        return RenderInput(original: original, crop: preview ? displayCrop : model.crop, style: style,
                           backgroundImage: backgroundImage, annotations: annotations,
                           originalScale: captureScale, template: plain ? nil : resolvedTemplate,
                           placement: model.template, customFrameImage: plain ? nil : customFrameImage)
    }

    // MARK: - Vorlage

    /// Das Dokument nennt eine Vorlage, die es weder mitgeliefert noch im Paket bzw. Vorlagenordner gibt.
    var isTemplateMissing: Bool { model.template != nil && resolvedTemplate == nil }

    /// Anmerkungen lassen sich nur bearbeiten, solange die Abbildung affin ist: Kippen 0/0 und
    /// (falls vorhanden) eine rechteckige Vorlage.
    var isAnnotationEditable: Bool {
        TemplateGeometry.isAffineEditable(template: resolvedTemplate, tilt: model.style.tilt)
    }

    /// Ob `tool` wählbar ist: die Auswahl immer, alle anderen nur bearbeitbar und bei affiner Abbildung.
    func canUse(_ tool: EditorTool) -> Bool {
        tool == .select || (!isReadOnly && isAnnotationEditable)
    }

    /// Löst `model.template` neu auf (z. B. nachdem eine eigene Vorlage angelegt wurde) und sperrt die
    /// Werkzeuge, wenn die neue Abbildung nicht affin ist.
    func resolveTemplate() {
        defer {
            scheduleRender()
            enforceAnnotationLock()
        }
        guard let id = model.template?.templateID else {
            setResolved(nil, frameData: nil, frameImage: nil)
            return
        }
        if let builtin = TemplateCatalog.builtin(id: id) {
            setResolved(builtin, frameData: nil, frameImage: nil)
            return
        }
        guard let custom = resolveCustomTemplate(id: id) else {
            setResolved(nil, frameData: nil, frameImage: nil)
            return
        }
        setResolved(custom.template, frameData: custom.frameData, frameImage: custom.frameImage)
    }

    private func setResolved(_ template: DeviceTemplate?, frameData: Data?, frameImage: CGImage?) {
        resolvedTemplate = template
        resolvedCustomFrameData = frameData
        customFrameImage = frameImage
    }

    /// Eigene Vorlage `id`: aus dieser Sitzung, aus dem geöffneten Paket, sonst aus dem Vorlagenordner
    /// (die Bilddaten werden einmal gelesen und daraus dekodiert).
    private func resolveCustomTemplate(id: String) -> ResolvedCustomTemplate? {
        if let known = sessionCustomTemplates[id] { return known }
        let store = CustomTemplateStore.shared
        let resolved: ResolvedCustomTemplate
        if let loadedCustomTemplate, loadedCustomTemplate.id == id {
            let data = loadedCustomFrameData ?? store.imageData(for: loadedCustomTemplate)
            resolved = ResolvedCustomTemplate(template: loadedCustomTemplate, frameData: data,
                                              frameImage: loadedCustomFrameImage ?? data.flatMap(Self.decodeImage))
        } else if let template = store.template(id: id) {
            let data = store.imageData(for: template)
            resolved = ResolvedCustomTemplate(template: template, frameData: data,
                                              frameImage: data.flatMap(Self.decodeImage))
        } else {
            return nil
        }
        // Ohne Bild nicht merken: ein später angelegtes bzw. wiederhergestelltes Bild wird dann noch gefunden.
        if resolved.frameData != nil { sessionCustomTemplates[id] = resolved }
        return resolved
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Wechselt die Vorlage (ein Undo-Schritt); Einpassen, Füllfarbe, Ausschnitt und Adresse bleiben.
    /// `nil` heißt ohne Gerät.
    func selectTemplate(id: String?) {
        // Ein offener Farbschritt (z. B. Füllfarbe) ist ein eigener, früherer Schritt, auch wenn der Aufruf
        // nicht aus dem Inspektor kommt (Fenster „Eigene Vorlage anlegen“).
        endTextEditing(commit: true)
        flushPendingEdit()
        guard id != model.template?.templateID else { return }
        apply(String(localized: "Vorlage")) { model in
            guard let id else {
                model.template = nil
                return
            }
            var placement = model.template ?? TemplatePlacement(templateID: id)
            placement.templateID = id
            model.template = placement
        }
    }

    /// Eigene Vorlagen wurden angelegt oder gelöscht: eine eigene bzw. fehlende Vorlage neu auflösen.
    private func customTemplatesDidChange() {
        guard let id = model.template?.templateID, TemplateCatalog.builtin(id: id) == nil else { return }
        resolveTemplate()
    }

    private func observeCustomTemplates() {
        templatesObserver = NotificationCenter.default.addObserver(
            forName: .customTemplatesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.customTemplatesDidChange() }
        }
    }

    /// Ohne affine Abbildung: nur die Auswahl ohne Interaktion, nichts ausgewählt (ein laufender Zuschnitt
    /// wird verworfen).
    private func enforceAnnotationLock() {
        guard !isAnnotationEditable else { return }
        if tool != .select { tool = .select }
        if !selection.isEmpty { selection = [] }
    }

    private var snapshot: Snapshot {
        Snapshot(model: model, backgroundImage: backgroundImage,
                 backgroundData: backgroundData, backgroundExtension: backgroundExtension)
    }

    // MARK: - Änderungen und Undo

    func apply(_ actionName: String, _ change: (inout DocumentModel) -> Void) {
        guard !isReadOnly else { return }
        // Eine offene Textbearbeitung ist ein eigener, früherer Schritt.
        endTextEditing(commit: true)
        flushPendingEdit()
        let before = snapshot
        var updated = model
        change(&updated)
        guard updated != model else { return }
        model = updated
        commit(from: before, actionName)
    }

    /// Beginnt einen Schritt ohne Undo-Schritt je Zwischenstand (Zug, Regler). Eine offene Textbearbeitung
    /// wird zuerst als eigener Schritt übernommen. Ist schon ein Schritt offen, passiert nichts.
    func beginContinuousChange() {
        guard !isReadOnly else { return }
        endTextEditing(commit: true)
        openContinuousStep()
    }

    private func openContinuousStep() {
        flushPendingEdit()
        guard continuousStart == nil else { return }
        continuousStart = snapshot
        continuousStartDirty = isDirty
    }

    /// Beginnt bzw. setzt einen Schritt fort, der kein Ende-Ereignis hat (Farbfenster).
    /// Er endet mit `flushPendingEdit()`: zeitgesteuert, vor jeder anderen Änderung und vor Undo/Redo.
    func beginPendingEdit(_ actionName: String) {
        guard !isReadOnly else { return }
        endTextEditing(commit: true)
        if pendingEditName == nil {
            flushPendingEdit()
            guard continuousStart == nil else { return }
            continuousStart = snapshot
            continuousStartDirty = isDirty
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
    /// Ist das Modell am Ende wieder wie am Anfang, gilt auch der Änderungszustand von damals.
    func endContinuousChange(_ actionName: String) {
        guard let start = continuousStart else { return }
        continuousStart = nil
        pendingEditName = nil
        defer { refreshUndoState() }
        guard start.model != model else {
            isDirty = continuousStartDirty
            return
        }
        registerUndo(restoring: start, actionName)
    }

    /// Verwirft einen offenen Schritt: Modell und Änderungszustand wie zu Beginn, kein Undo-Schritt.
    func cancelContinuousChange() {
        guard let start = continuousStart else { return }
        continuousStart = nil
        pendingEditName = nil
        if model != start.model {
            model = start.model
            pruneSelection()
            scheduleRender()
        }
        isDirty = continuousStartDirty
        refreshUndoState()
    }

    func setBackgroundImage(data: Data, ext: String) throws {
        guard !isReadOnly else { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw EditorError.unreadableImage }
        endTextEditing(commit: true)
        flushPendingEdit()
        let before = snapshot
        let ext = ext.lowercased()
        backgroundImage = image
        backgroundData = data
        backgroundExtension = ext
        model.style.background = .image(file: "background.\(ext)")
        commit(from: before, String(localized: "Hintergrundbild"))
    }

    /// Bricht einen laufenden Mauszug ab und schließt eine offene Textbearbeitung und einen offenen
    /// Farbschritt ab, damit Historie, Modell und Änderungszustand übereinstimmen (vor Undo/Redo und Sichern).
    func finishOpenEdits() {
        interruptInteraction?()
        endTextEditing(commit: true)
        flushPendingEdit()
    }

    /// Schließt zuerst offene Bearbeitungen ab (`finishOpenEdits`); während eines Reglerzugs passiert nichts.
    func undo() {
        finishOpenEdits()
        guard continuousStart == nil else { return }
        undoManager?.undo()
    }

    func redo() {
        finishOpenEdits()
        guard continuousStart == nil else { return }
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
        pruneSelection()
        if tool == .crop { cropDraft = CropGeometry.initialRect(crop: model.crop, bounds: originalBounds) }
        commit(from: current, actionName)
    }

    // MARK: - Textbearbeitung

    /// Öffnet die Textbearbeitung für eine Text- oder Notiz-Anmerkung und wählt sie aus.
    /// `isNew`: Sie wurde gerade in einem noch offenen Schritt (`beginContinuousChange`) hinzugefügt;
    /// Hinzufügen und Text werden dann ein Undo-Schritt, Abbrechen entfernt sie ohne Spur in der Historie.
    func beginTextEditing(_ id: UUID, isNew: Bool) {
        guard !isReadOnly, editingTextID != id,
              let annotation = model.annotations.first(where: { $0.id == id }),
              let frame = Self.textFrame(of: annotation)
        else { return }
        endTextEditing(commit: true)
        openContinuousStep()
        textEditIsNew = isNew
        textEditStartHeight = frame.height
        selection = [id]
        editingTextID = id
        updateEditingText(Self.text(of: annotation) ?? "")
    }

    /// Übernimmt den getippten Text live; die Rahmenhöhe wächst mit dem Inhalt (Core-Text-Messung wie
    /// beim Rendern).
    func updateEditingText(_ string: String) {
        updateEditedAnnotation(string: string) { _ in }
    }

    /// Änderung aus der Optionsleiste an der gerade bearbeiteten Anmerkung (Schriftgröße, fett, Farbe,
    /// Hintergrund, Notizfarbe): gehört zum Schritt der Bearbeitung. Die Rahmenhöhe wird mit dem aktuellen
    /// Text neu gemessen.
    func applyToEditingText(_ change: (inout Annotation) -> Void) {
        updateEditedAnnotation(string: nil, change)
    }

    /// Ändert die bearbeitete Anmerkung live (`string`: neuer Text, `nil` behält ihn) und passt die Rahmenhöhe
    /// an den Inhalt an.
    private func updateEditedAnnotation(string: String?, _ change: (inout Annotation) -> Void) {
        guard let id = editingTextID, continuousStart != nil else { return }
        let scale = captureScale
        let minimumHeight = textEditStartHeight
        applyLive { model in
            guard let index = model.annotations.firstIndex(where: { $0.id == id }) else { return }
            var annotation = model.annotations[index]
            change(&annotation)
            let string = string ?? Self.text(of: annotation) ?? ""
            let needed = AnnotationTextLayout.requiredFrameHeight(of: annotation, string: string,
                                                                  originalScale: scale) ?? 0
            model.annotations[index] = Self.withText(annotation, string, height: max(minimumHeight, needed))
        }
    }

    /// Schließt die Textbearbeitung. `commit`: ein Undo-Schritt („Text bearbeiten“ bzw. für neue
    /// „Text/Notiz hinzufügen“); leerer Text löscht die Anmerkung (eine neue verschwindet spurlos).
    /// Ohne `commit` (Esc) bleibt alles wie vor der Bearbeitung.
    func endTextEditing(commit: Bool) {
        guard let id = editingTextID else { return }
        editingTextID = nil
        let annotation = model.annotations.first { $0.id == id }
        let string = annotation.flatMap(Self.text(of:)) ?? ""
        let isEmpty = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard commit, !(textEditIsNew && isEmpty) else {
            cancelContinuousChange()
            return
        }
        if annotation != nil, isEmpty {
            applyLive { $0.annotations.removeAll { $0.id == id } }
            selection.remove(id)
            endContinuousChange(String(localized: "Löschen"))
        } else if textEditIsNew, let annotation {
            if case .note = annotation.kind {
                endContinuousChange(DragOperation.addActionName(.note))
            } else {
                endContinuousChange(DragOperation.addActionName(.text))
            }
        } else {
            endContinuousChange(String(localized: "Text bearbeiten"))
        }
    }

    private static func textFrame(of a: Annotation) -> CGRect? {
        switch a.kind {
        case let .text(frame, _, _, _, _), let .note(frame, _, _): frame.standardized
        default: nil
        }
    }

    private static func text(of a: Annotation) -> String? {
        switch a.kind {
        case let .text(_, string, _, _, _), let .note(_, string, _): string
        default: nil
        }
    }

    /// Text bzw. Notiz mit neuem Text und (falls angegeben) neuer Rahmenhöhe; andere Arten unverändert.
    private static func withText(_ a: Annotation, _ string: String, height: CGFloat?) -> Annotation {
        var result = a
        switch a.kind {
        case let .text(frame, _, fontSize, bold, background):
            var frame = frame.standardized
            if let height { frame.size.height = height }
            result.kind = .text(frame: frame, string: string, fontSize: fontSize, bold: bold, background: background)
        case let .note(frame, _, noteColor):
            var frame = frame.standardized
            if let height { frame.size.height = height }
            result.kind = .note(frame: frame, string: string, noteColor: noteColor)
        default:
            break
        }
        return result
    }

    // MARK: - Zuschnitt

    private func toolDidChange(from old: EditorTool) {
        guard tool != old else { return }
        endTextEditing(commit: true)
        if tool == .crop {
            interruptInteraction?()
            selection = []
            cropDraft = CropGeometry.initialRect(crop: model.crop, bounds: originalBounds)
        } else if old == .crop {
            interruptInteraction?()
            cropDraft = nil
        }
        if tool == .crop || old == .crop { scheduleRender() }
    }

    /// „Fertig“ bzw. ↩: übernimmt den Rahmen als einen Undo-Schritt und verlässt das Werkzeug.
    func commitCrop() {
        guard tool == .crop, let draft = cropDraft else { return }
        let crop = CropGeometry.committed(draft, bounds: originalBounds)
        apply(String(localized: "Zuschneiden")) { $0.crop = crop }
        tool = .select
        pruneSelection()
    }

    /// Esc: verwirft den Rahmen und verlässt das Werkzeug.
    func discardCrop() {
        guard tool == .crop else { return }
        tool = .select
    }

    /// „Zurücksetzen“: entfernt den Zuschnitt (`crop = nil`, ein Undo-Schritt); der Rahmen umfasst
    /// wieder das ganze Original.
    func resetCrop() {
        apply(String(localized: "Zuschnitt zurücksetzen")) { $0.crop = nil }
        if tool == .crop { cropDraft = originalBounds }
    }

    // MARK: - Auswahl und Ebenen

    /// Wählt `id` aus. Mit `extend` wird sie zur Auswahl hinzugefügt bzw. wieder entfernt;
    /// `nil` hebt die Auswahl auf (mit `extend` bleibt sie unverändert).
    func select(_ id: UUID?, extend: Bool) {
        guard let id else {
            if !extend { selection = [] }
            return
        }
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    func deleteSelection() {
        guard !selection.isEmpty, !isReadOnly else { return }
        endTextEditing(commit: true)
        let ids = selection
        apply(String(localized: "Löschen")) { $0.annotations.removeAll { ids.contains($0.id) } }
        selection = []
    }

    /// Dupliziert die Auswahl um 20 px nach rechts unten versetzt, ganz oben; die Kopien werden ausgewählt.
    func duplicateSelection() {
        guard !selection.isEmpty, !isReadOnly else { return }
        // Erst den Text übernehmen: die Kopien zeigen ihn, eine leere neue Anmerkung verschwindet.
        endTextEditing(commit: true)
        guard !selection.isEmpty else { return }
        let copies = model.annotations.filter { selection.contains($0.id) }.map { annotation in
            var copy = AnnotationGeometry.moved(annotation, by: CGVector(dx: 20, dy: 20))
            copy.id = UUID()
            return copy
        }
        apply(String(localized: "Duplizieren")) { $0.annotations.append(contentsOf: copies) }
        selection = Set(copies.map(\.id))
    }

    /// Hebt jede ausgewählte Anmerkung um eine Ebene an (spätere Anmerkungen liegen oben).
    func bringForward() {
        let ids = selection
        apply(String(localized: "Nach vorne")) { model in
            var list = model.annotations
            for index in stride(from: list.count - 2, through: 0, by: -1)
            where ids.contains(list[index].id) && !ids.contains(list[index + 1].id) {
                list.swapAt(index, index + 1)
            }
            model.annotations = list
        }
    }

    /// Senkt jede ausgewählte Anmerkung um eine Ebene ab.
    func sendBackward() {
        let ids = selection
        apply(String(localized: "Nach hinten")) { model in
            var list = model.annotations
            for index in stride(from: 1, to: list.count, by: 1)
            where ids.contains(list[index].id) && !ids.contains(list[index - 1].id) {
                list.swapAt(index, index - 1)
            }
            model.annotations = list
        }
    }

    /// Ändert alle ausgewählten Anmerkungen in einem Undo-Schritt; `change` lässt unpassende Arten unverändert.
    func applyToSelection(_ actionName: String, _ change: (inout Annotation) -> Void) {
        let ids = selection
        apply(actionName) { model in
            for index in model.annotations.indices where ids.contains(model.annotations[index].id) {
                change(&model.annotations[index])
            }
        }
    }

    /// Wie `applyToSelection`, aber ohne Undo-Schritt (Reglerzug, Farbfenster).
    func applyLiveToSelection(_ change: (inout Annotation) -> Void) {
        let ids = selection
        applyLive { model in
            for index in model.annotations.indices where ids.contains(model.annotations[index].id) {
                change(&model.annotations[index])
            }
        }
    }

    /// Entfernt aus der Auswahl, was es nicht mehr gibt oder was nicht sichtbar ist (`interactiveAnnotations`).
    private func pruneSelection() {
        let existing = Set(interactiveAnnotations.map(\.id))
        if !selection.isSubset(of: existing) { selection.formIntersection(existing) }
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
        Renderer.render(renderInput(preview: false), outputScale: ExportScaling.factor(scale, captureScale: captureScale))
    }

    /// Beendet laufende Arbeit beim Schließen des Fensters.
    func tearDown() {
        isTornDown = true
        renderTask?.cancel()
        renderTask = nil
        previewMaxPixelSize = nil
        noticeTask?.cancel()
        if let templatesObserver { NotificationCenter.default.removeObserver(templatesObserver) }
        templatesObserver = nil
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
            let input = renderInput(preview: true)
            let canvas = displaySize
            guard canvas.width > 0, canvas.height > 0 else {
                renderFailed = true
                return
            }
            let scale = min(1, maxSize.width / canvas.width, maxSize.height / canvas.height)
            let image = await Task.detached(priority: .userInitiated) {
                Renderer.render(input, outputScale: scale)
            }.value
            guard !Task.isCancelled else { return }
            if let image {
                if current > shownGeneration {
                    preview = image
                    shownGeneration = current
                }
                if renderFailed { renderFailed = false }
            } else if current == generation {
                renderFailed = true
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
