import AppKit
import Observation
import OSLog
import ScreenXCore

/// Zugriff auf die Einstellungen und Mitteilungen der App. Wird nach dem Anlegen des `AppCoordinator`
/// verbunden, damit `RecordingCoordinator` und Engine ohne Zyklus im Initialisierer auskommen.
@MainActor
final class SettingsLink {
    var get: () -> AppSettings = { .defaults(home: FileManager.default.homeDirectoryForCurrentUser) }
    var set: (AppSettings) -> Void = { _ in }
    var notify: (String) -> Void = { _ in }
    var openSettings: () -> Void = {}
}

/// Ablauf einer Videoaufnahme: Leiste → Auswahl → Speicherplatz-Warnung → Countdown → Aufnahme → Fertigstellen.
@MainActor @Observable
final class RecordingCoordinator {
    enum Phase: Equatable {
        case idle
        case bar
        /// Auswahl, Rückfragen und Start der Engine.
        case preparing
        case countdown
        /// Läuft, pausiert oder wird gesichert (siehe `engine.state`).
        case recording
    }

    nonisolated private static let logger = Logger(subsystem: "com.screenx.app", category: "recording")
    private static let lowDiskWarningBytes: Int64 = 1_000_000_000

    private(set) var phase: Phase = .idle
    let engine: RecordingEngine
    /// Für das Blinken der Laufzeit in der Pause (1 s).
    private(set) var blinkOn = true
    /// Profil der laufenden Aufnahme (Infozeile im Menü).
    private(set) var activeProfile: RecordingProfile?

    var isRecording: Bool { phase == .recording }

    /// Fertige Aufnahme (für den Schnellzugriff in Task 9). Nur bei einer vorhandenen Datei.
    @ObservationIgnored var onFinished: ((RecordingResult) -> Void)?

    @ObservationIgnored private let link: SettingsLink
    @ObservationIgnored private let overlay: OverlayController
    @ObservationIgnored private var bar: RecordingBarPanel?
    @ObservationIgnored private var countdown: CountdownWindow?
    @ObservationIgnored private var frameWindow: RecordingFrameWindow?
    @ObservationIgnored private let clicks = ClickHighlighter()
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var run: Run?

    /// Die laufende Aufnahme; verhindert, dass ein Ergebnis zweimal ausgeliefert wird.
    private struct Run {
        let estimateMegabytesPerMinute: Double
        var warnedAboutSize = false
    }

    init(overlay: OverlayController, link: SettingsLink) {
        self.overlay = overlay
        self.link = link
        engine = RecordingEngine(settings: { link.get() })
        engine.onAutoStop = { [weak self] reason in
            Task { await self?.handleAutoStop(reason) }
        }
    }

    // MARK: - Steuerung

    /// ⌥⇧6: öffnet die Leiste, schließt sie wieder, bricht den Countdown ab oder stoppt die Aufnahme.
    func toggle() {
        switch phase {
        case .idle: showBar()
        case .bar: closeBar()
        case .countdown: countdown?.cancel()
        case .preparing: break
        case .recording: stop()
        }
    }

    func stop() {
        guard phase == .recording, engine.state != .finishing else { return }
        Task {
            let result = await engine.stop()
            complete(result)
        }
    }

    func togglePause() {
        guard phase == .recording else { return }
        switch engine.state {
        case .recording: engine.pause()
        case .paused: engine.resume()
        case .idle, .finishing: break
        }
    }

    /// Fragt nach und löscht die Aufnahme.
    func discard() {
        guard phase == .recording, engine.state != .finishing else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Aufnahme verwerfen?")
        alert.informativeText = String(localized: "Die Aufnahme wird gelöscht.")
        alert.addButton(withTitle: String(localized: "Verwerfen"))
        let cancel = alert.addButton(withTitle: String(localized: "Abbrechen"))
        cancel.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn, phase == .recording else { return }
        run = nil
        Task {
            await engine.discard()
            endRecordingUI()
        }
    }

    // MARK: - Leiste

    private func showBar() {
        guard phase == .idle else { return }
        let screen = Self.screenUnderPointer() ?? NSScreen.main
        let source = screen.map { CGSize(width: $0.frame.width * $0.backingScaleFactor,
                                         height: $0.frame.height * $0.backingScaleFactor) } ?? CGSize(width: 1920, height: 1080)
        let model = RecordingBarModel(link: link, sourceSize: source)
        model.onStart = { [weak self] in self?.startFromBar() }
        model.onClose = { [weak self] in self?.closeBar() }
        model.onEditProfiles = { [weak self] in
            self?.closeBar()
            SettingsNavigation.shared.tab = .video
            self?.link.openSettings()
        }
        let bar = RecordingBarPanel(model: model)
        self.bar = bar
        phase = .bar
        if let screen { bar.show(on: screen) }
    }

    private func closeBar() {
        bar?.close()
        bar = nil
        if phase == .bar { phase = .idle }
    }

    private func startFromBar() {
        guard phase == .bar, let model = bar?.model else { return }
        let profile = model.effectiveProfile
        let setup = model.setup
        bar?.close()
        bar = nil
        phase = .preparing
        Task {
            await prepareAndStart(mode: setup.mode, profile: profile, setup: setup)
            if phase != .recording { cancelPreparation() }
        }
    }

    // MARK: - Start

    private func prepareAndStart(mode: CaptureMode, profile: RecordingProfile, setup: RecordingSetup) async {
        guard ScreenPermission.isGranted else {
            ScreenPermission.requestOrExplain()
            return
        }

        // Auswahl je Modus. `nil` = abgebrochen.
        let target: RecordingTarget
        let area: CGRect
        do {
            switch mode {
            case .area:
                guard let picked = try await overlay.selectAreaRect(),
                      let global = Self.globalRect(local: picked.1, display: picked.0) else { return }
                target = .area(picked.0, picked.1)
                area = global
            case .window:
                guard let id = try await overlay.selectWindowID() else { return }
                target = .window(id)
                area = Self.windowFrame(id) ?? Self.screenUnderPointer()?.frame ?? .zero
            case .fullscreen:
                guard let screen = Self.screenUnderPointer(), let id = Self.displayID(of: screen) else {
                    throw CaptureError.displayNotFound
                }
                target = .display(id)
                area = screen.frame
            }
        } catch {
            report(error)
            return
        }

        let settings = link.get()
        if let free = Self.freeSpace(near: settings.saveDirectory), free < Self.lowDiskWarningBytes {
            guard confirmLowDisk(free: free) else { return }
        }

        var profile = profile
        if profile.microphone, !(await MicrophonePermission.request()) {
            profile.microphone = false
            link.notify(String(localized: "Das Mikrofon ist nicht freigegeben. Die Aufnahme läuft ohne Mikrofon."))
        }

        let seconds = settings.countdown.rawValue
        if mode == .area, let screen = Self.screen(containing: area) {
            let frame = RecordingFrameWindow(area: area, screenFrame: screen.frame)
            frame.dimsOutside = seconds > 0
            frame.show()
            frameWindow = frame
        }
        if seconds > 0 {
            phase = .countdown
            let window = CountdownWindow(center: CGPoint(x: area.midX, y: area.midY))
            countdown = window
            let finished = await window.run(seconds: seconds)
            countdown = nil
            guard finished else { return }
            phase = .preparing
        }
        frameWindow?.dimsOutside = false

        // Klick-Kreise müssen vor dem Start sichtbar sein, sonst fehlen sie im Filter.
        var included: [CGWindowID] = []
        if profile.highlightClicks, mode != .window {
            clicks.start()
            included = clicks.windowIDs
            try? await Task.sleep(for: .milliseconds(50))
        }

        do {
            try await engine.start(target: target, profile: profile, systemAudio: profile.systemAudio,
                                   microphone: profile.microphone, includedWindowIDs: included)
        } catch is CancellationError {
            return
        } catch {
            report(error)
            return
        }
        // Remembered only for a recording that actually started (not after Esc or a failed start).
        var updated = link.get()
        updated.lastRecordingSetup = setup
        link.set(updated)
        let scale = Self.screen(containing: area)?.backingScaleFactor ?? 2
        let source = CGSize(width: area.width * scale, height: area.height * scale)
        run = Run(estimateMegabytesPerMinute: RecordingEstimate.megabytesPerMinute(profile: profile, source: source))
        activeProfile = profile
        phase = .recording
        startMonitor()
    }

    /// Räumt nach Abbruch oder Fehler vor dem Aufnahmestart auf.
    private func cancelPreparation() {
        countdown?.cancel()
        countdown = nil
        frameWindow?.orderOut(nil)
        frameWindow = nil
        clicks.stop()
        phase = .idle
    }

    private func confirmLowDisk(free: Int64) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Wenig freier Speicherplatz")
        let amount = Self.formatBytes(free)
        alert.informativeText = String(localized: "Am Speicherort sind nur noch \(amount) frei. Die Aufnahme endet, wenn weniger als 300 MB frei sind.")
        alert.addButton(withTitle: String(localized: "Trotzdem starten"))
        let cancel = alert.addButton(withTitle: String(localized: "Abbrechen"))
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Während der Aufnahme

    /// Blinken in der Pause und die einmalige Warnung, wenn die Datei deutlich größer wird als geschätzt.
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                ticks += 1
                if self.engine.state == .paused {
                    if ticks % 2 == 0 { self.blinkOn.toggle() }
                } else if !self.blinkOn {
                    self.blinkOn = true
                }
                self.checkSize()
            }
        }
    }

    private func checkSize() {
        guard var run, !run.warnedAboutSize, engine.elapsed >= 60 else { return }
        let megabytesPerMinute = Double(engine.bytesWritten) / 1_000_000 / (engine.elapsed / 60)
        guard megabytesPerMinute > 2 * run.estimateMegabytesPerMinute else { return }
        run.warnedAboutSize = true
        self.run = run
        link.notify(String(localized: "Die Aufnahme wird größer als geschätzt."))
    }

    // MARK: - Ende

    private func handleAutoStop(_ reason: RecordingStopReason) async {
        let text: String
        switch reason {
        case .lowDisk:
            text = String(localized: "Die Aufnahme wurde beendet, weil der Speicherplatz knapp ist.")
        case .streamEnded(let detail):
            text = String(localized: "Die Aufnahme wurde beendet: \(detail)")
        case .writerFailed(let detail):
            text = String(localized: "Die Aufnahme wurde beendet, weil das Schreiben fehlgeschlagen ist: \(detail)")
        }
        link.notify(text)
        let result = await engine.stop()
        complete(result)
    }

    /// Liefert das Ergebnis genau einmal aus. Ohne Datei (kein Bild aufgenommen) gibt es nur einen Hinweis.
    private func complete(_ result: RecordingResult) {
        guard run != nil else { return }
        run = nil
        endRecordingUI()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: result.url.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue, result.size > 0 else {
            link.notify(String(localized: "Die Aufnahme enthält kein Bild und wurde nicht gesichert."))
            return
        }
        if !result.warnings.isEmpty {
            link.notify(result.warnings.joined(separator: "\n"))
        }
        onFinished?(result)
    }

    private func endRecordingUI() {
        monitor?.cancel()
        monitor = nil
        frameWindow?.orderOut(nil)
        frameWindow = nil
        clicks.stop()
        blinkOn = true
        activeProfile = nil
        phase = .idle
    }

    private func report(_ error: any Error) {
        let message = (error as? CaptureError)?.localizedDescription
            ?? String(localized: "Aufnahme fehlgeschlagen: \(error.localizedDescription)")
        Self.logger.error("\(message, privacy: .public)")
        link.notify(message)
    }

    // MARK: - Anzeige

    /// Laufzeit als `mm:ss` bzw. `h:mm:ss`.
    var elapsedText: String {
        let total = Int(engine.elapsed)
        let hours = total / 3600
        let minutes = total / 60 % 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// Z. B. „1080p · 24 fps · HEVC · 312 MB“.
    var infoLine: String {
        var parts: [String] = []
        if let activeProfile {
            parts.append(activeProfile.resolution.label)
            parts.append("\(activeProfile.fps) fps")
            parts.append(activeProfile.output == .gif ? "GIF" : activeProfile.codec.shortLabel)
        }
        parts.append(Self.formatBytes(engine.bytesWritten))
        return parts.joined(separator: " · ")
    }

    static func formatBytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "de_DE")))
    }

    // MARK: - Geometrie

    private static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Bildschirm mit der größten Überlappung.
    private static func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            area(lhs.frame.intersection(rect)) < area(rhs.frame.intersection(rect))
        }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// Rechteck relativ zur oberen linken Ecke des Monitors → AppKit-Global-Koordinaten.
    private static func globalRect(local: CGRect, display: CGDirectDisplayID) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { displayID(of: $0) == display }) else { return nil }
        let frame = screen.frame
        return CGRect(x: frame.minX + local.minX, y: frame.maxY - local.maxY, width: local.width, height: local.height)
    }

    /// Fensterrahmen in AppKit-Global-Koordinaten laut Window Server.
    private static func windowFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        let screens = NSScreen.screens
        let primaryHeight = (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height ?? 0
        return CoordinateSpace.toBottomLeft(rect, primaryHeight: primaryHeight)
    }

    /// Freier Platz am Speicherort; existiert er noch nicht, am nächsten vorhandenen Elternordner.
    private static func freeSpace(near url: URL) -> Int64? {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return RecordingEngine.freeSpace(at: current)
    }
}
