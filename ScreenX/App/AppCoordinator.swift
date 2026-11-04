import AppKit
import Observation
import OSLog
import ScreenXCore
import UserNotifications

/// Verbindet Tastenkürzel, Menü, Aufnahme und Schnellzugriff. Hält die Einstellungen und
/// speichert sie bei jeder Änderung.
@MainActor
@Observable
final class AppCoordinator {
    nonisolated private static let logger = Logger(subsystem: "com.screenx.app", category: "app")

    /// Schreibt bei Änderung über den `SettingsStore` und registriert die Tastenkürzel neu.
    var settings: AppSettings {
        get { storedSettings }
        set {
            guard newValue != storedSettings else { return }
            let hotkeysChanged = newValue.hotkeys != storedSettings.hotkeys
            storedSettings = newValue
            store.save(newValue)
            if hotkeysChanged { registerHotkeys() }
        }
    }

    private(set) var hotkeyErrors: [CaptureMode: HotkeyError] = [:]
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

    init(store: SettingsStore = SettingsStore(defaults: .standard)) {
        self.store = store
        self.storedSettings = store.load()
        let service = CaptureService()
        self.service = service
        self.overlay = OverlayController(service: service)
        // `onEdit` bleibt in M1 nil.
        quickAccess = QuickAccessController { [weak self] in
            self?.settings ?? .defaults(home: FileManager.default.homeDirectoryForCurrentUser)
        }
        hotkeyCenter = HotkeyCenter { [weak self] mode in
            guard let self else { return }
            Task { await self.capture(mode) }
        }
        registerHotkeys()
        Task { @MainActor in ScreenPermission.requestAtLaunch() }
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
        quickAccess?.show(result)
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
        hotkeyErrors = hotkeyCenter.register(settings.hotkeys)
        for (mode, error) in hotkeyErrors {
            Self.logger.error(
                "Kürzel für \(mode.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
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
    nonisolated private static func postNotification(_ message: String) async {
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
