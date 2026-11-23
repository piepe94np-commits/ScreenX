import AppKit
import Observation
import OSLog
import ScreenXCore
import SwiftUI
import UserNotifications

/// Verbindet Tastenkürzel, Menü, Aufnahme, Schnellzugriff und Editor. Hält die Einstellungen und
/// speichert sie bei jeder Änderung.
@MainActor
@Observable
final class AppCoordinator {
    nonisolated static let logger = Logger(subsystem: "com.screenx.app", category: "app")

    /// Schreibt bei Änderung über den `SettingsStore` und registriert die Tastenkürzel neu.
    var settings: AppSettings {
        get { storedSettings }
        set {
            guard newValue != storedSettings else { return }
            let hotkeysChanged = newValue.hotkeys != storedSettings.hotkeys
                || newValue.videoHotkey != storedSettings.videoHotkey
            storedSettings = newValue
            store.save(newValue)
            if hotkeysChanged { registerHotkeys() }
        }
    }

    private(set) var hotkeyErrors: [CaptureMode: HotkeyError] = [:]
    private(set) var videoHotkeyError: HotkeyError?
    /// Videoaufnahme (Leiste, Countdown, Menüleistenzustand).
    let videoRecorder: RecordingCoordinator
    private(set) var lastCapture: Capture?
    /// Modus, dessen Kürzel gerade aufgenommen wird. Währenddessen sind alle globalen Kürzel abgemeldet.
    private(set) var recordingMode: CaptureMode?

    private var storedSettings: AppSettings
    private let store: SettingsStore
    private let service: CaptureService
    private let overlay: OverlayController
    @ObservationIgnored private var quickAccess: QuickAccessController?
    @ObservationIgnored private var hotkeyCenter: HotkeyCenter?
    /// Der einzige lokale keyDown-Monitor des Kürzel-Rekorders.
    @ObservationIgnored private var recordingMonitor: Any?
    /// Beenden die Aufnahme, wenn die App inaktiv wird oder das Einstellungsfenster schließt.
    @ObservationIgnored private var recordingObservers: [any NSObjectProtocol] = []
    /// SwiftUI-Aktion zum Öffnen der Einstellungen; das Menüleisten-Menü trägt sie ein.
    @ObservationIgnored var openSettingsAction: OpenSettingsAction?
    private let settingsLink: SettingsLink

    init(store: SettingsStore = SettingsStore(defaults: .standard)) {
        self.store = store
        self.storedSettings = store.load()
        let service = CaptureService()
        self.service = service
        let overlay = OverlayController(service: service)
        self.overlay = overlay
        let settingsLink = SettingsLink()
        self.settingsLink = settingsLink
        self.videoRecorder = RecordingCoordinator(overlay: overlay, link: settingsLink)
        let quickAccess = QuickAccessController { [weak self] in
            self?.settings ?? .defaults(home: FileManager.default.homeDirectoryForCurrentUser)
        }
        self.quickAccess = quickAccess
        hotkeyCenter = HotkeyCenter(
            handler: { [weak self] mode in
                guard let self else { return }
                Task { await self.capture(mode) }
            },
            videoHandler: { [weak self] in self?.videoRecorder.toggle() }
        )
        settingsLink.get = { [weak self] in
            self?.settings ?? .defaults(home: FileManager.default.homeDirectoryForCurrentUser)
        }
        settingsLink.set = { [weak self] in self?.settings = $0 }
        settingsLink.notify = { message in Task { await AppCoordinator.postNotification(message) } }
        settingsLink.openSettings = { [weak self] in self?.showSettings() }
        videoRecorder.onFinished = { [weak quickAccess] result in quickAccess?.show(recording: result) }
        TrimWindow.onResult = { [weak quickAccess] result in quickAccess?.show(recording: result) }
        registerHotkeys()
        quickAccess.onEdit = { [weak self] capture in self?.openEditor(for: capture) }
        // Editor und Coordinator teilen dieselben Einstellungen.
        EditorWindowController.settingsSource = Bindable(self).settings
        EditorWindowController.settingsOpener = { [weak self] in self?.showSettings() }
        Task { @MainActor in ScreenPermission.requestAtLaunch() }
        Task { @MainActor [weak self] in self?.offerLeftoverRecovery() }
    }

    // MARK: - Unvollständige Aufnahmen

    /// Sucht beim Start nach `.mov`-Resten im Speicherort (z. B. nach einem Absturz) und bietet an,
    /// sie fertigzustellen. Das läuft im Hintergrund; danach erscheint je Datei eine Karte.
    private func offerLeftoverRecovery() {
        let leftovers = RecordingFinalizer.leftovers(in: settings.saveDirectory)
        guard !leftovers.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Unvollständige Aufnahme gefunden")
        alert.informativeText = leftovers.map(\.lastPathComponent).joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Fertigstellen"))
        alert.addButton(withTitle: String(localized: "Später"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [weak self] in
            for mov in leftovers {
                do {
                    let url = try await RecordingFinalizer.finalize(mov: mov)
                    let duration = await VideoFileInfo.info(url: url)?.duration ?? 0
                    self?.quickAccess?.show(recording: RecordingResult(
                        url: url, duration: duration, size: VideoFileInfo.fileSize(url), warnings: []
                    ))
                } catch {
                    Self.logger.error(
                        "Fertigstellen fehlgeschlagen: \(mov.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    await Self.postNotification(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Aufnahme

    func capture(_ mode: CaptureMode) async {
        guard ScreenPermission.isGranted else {
            ScreenPermission.requestOrExplain()
            return
        }
        let result: Capture?
        do {
            switch mode {
            case .area:
                result = try await overlay.selectArea()
            case .window:
                result = try await overlay.selectWindow(shadow: settings.windowShadow)
            case .fullscreen:
                result = try await captureFullscreen()
            }
        } catch {
            report(error)
            return
        }
        // `nil`: vom Benutzer abgebrochen.
        guard let result else { return }
        lastCapture = result
        switch settings.afterCapture {
        case .quickAccess: quickAccess?.show(result)
        case .openEditor: openEditor(for: result)
        }
    }

    /// Zeigt die letzte Aufnahme erneut im Schnellzugriff.
    func showLastCapture() {
        guard let lastCapture else { return }
        quickAccess?.show(lastCapture)
    }

    /// Monitor mit dem Mauszeiger, sonst der erste.
    private func captureFullscreen() async throws -> Capture {
        let displays = try await service.displays()
        let mouse = NSEvent.mouseLocation
        guard let display = displays.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? displays.first else {
            throw CaptureError.displayNotFound
        }
        let image = try await service.captureDisplay(display.id)
        return Capture(image: image, scale: display.scale, mode: .fullscreen, date: Date())
    }

    // MARK: - Tastenkürzel

    /// Setzt oder entfernt (`nil`) das Kürzel eines Modus. Ein Kürzel gehört höchstens einem Modus.
    func setHotkey(_ combo: KeyCombo?, for mode: CaptureMode) {
        var hotkeys = settings.hotkeys
        if let combo {
            for (other, existing) in hotkeys where other != mode && existing == combo {
                hotkeys[other] = nil
            }
        }
        hotkeys[mode] = combo
        settings.hotkeys = hotkeys
    }

    /// Nimmt das nächste Kürzel für `mode` auf. Eine laufende Aufnahme eines anderen Modus endet.
    /// Die globalen Kürzel werden abgemeldet, damit auch das aktuelle Kürzel erneut aufgenommen werden kann.
    func startRecording(_ mode: CaptureMode) {
        removeRecordingMonitor()
        recordingMode = mode
        hotkeyCenter?.unregisterAll()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleRecording(event)
            return nil
        }
        let center = NotificationCenter.default
        let stop: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
        recordingObservers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: stop)
        )
        if let window = NSApp.keyWindow {
            recordingObservers.append(
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: stop)
            )
        }
    }

    /// Beendet die Aufnahme (falls eine läuft) und meldet die Kürzel wieder an.
    func stopRecording() {
        removeRecordingMonitor()
        guard recordingMode != nil else { return }
        recordingMode = nil
        registerHotkeys()
    }

    private func removeRecordingMonitor() {
        for observer in recordingObservers { NotificationCenter.default.removeObserver(observer) }
        recordingObservers = []
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
            self.recordingMonitor = nil
        }
    }

    /// Esc bricht ab; ein Kürzel braucht mindestens einen von ⌘⌥⌃ (⇧ allein genügt nicht).
    private func handleRecording(_ event: NSEvent) {
        guard let mode = recordingMode else { return }
        if event.keyCode == Self.escapeKeyCode {
            stopRecording()
            return
        }
        let modifiers = Self.modifiers(from: event.modifierFlags)
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else {
            NSSound.beep()
            return
        }
        // Erst setzen, dann beenden: so wird nur der neue Satz registriert.
        setHotkey(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers), for: mode)
        stopRecording()
    }

    nonisolated private static let escapeKeyCode: UInt16 = 53

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private func registerHotkeys() {
        guard recordingMode == nil, let hotkeyCenter else { return }
        let result = hotkeyCenter.register(settings.hotkeys, video: settings.videoHotkey)
        hotkeyErrors = result.modes
        videoHotkeyError = result.video
        for (mode, error) in hotkeyErrors {
            Self.logger.error(
                "Kürzel für \(mode.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        if let error = videoHotkeyError {
            Self.logger.error("Kürzel für Video: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Fehler

    private func report(_ error: any Error) {
        let reason: String
        if let error = error as? CaptureError, case .failed(let detail) = error {
            reason = detail
        } else {
            reason = error.localizedDescription
        }
        let message = String(localized: "Aufnahme fehlgeschlagen: \(reason)")
        Self.logger.error("\(message, privacy: .public)")
        Task { await Self.postNotification(message) }
    }

    /// Fragt die Mitteilungs-Freigabe erst beim ersten Fehler an. Ohne Freigabe bleibt es beim Log.
    nonisolated static func postNotification(_ message: String) async {
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert])
        } catch {
            logger.error("Mitteilungen nicht verfügbar: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard granted else {
            logger.info("Mitteilungen nicht erlaubt, Fehler nur protokolliert")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "ScreenX"
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            logger.error("Mitteilung fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }
}
