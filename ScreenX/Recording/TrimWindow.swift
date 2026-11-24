import AppKit
import AVKit
import OSLog
import ScreenXCore
import SwiftUI

/// Laufende Kürzen- und GIF-Aufträge je Quelldatei. Die Videokarte einer Datei blendet sich nicht aus,
/// solange für sie ein Auftrag läuft.
@MainActor
final class VideoJobs {
    static let shared = VideoJobs()

    /// Wird nach jedem `begin`/`end` aufgerufen.
    var onChange: (() -> Void)?
    private var counts: [URL: Int] = [:]

    func isBusy(_ url: URL) -> Bool {
        counts[url.standardizedFileURL, default: 0] > 0
    }

    func begin(_ url: URL) {
        counts[url.standardizedFileURL, default: 0] += 1
        onChange?()
    }

    func end(_ url: URL) {
        let key = url.standardizedFileURL
        let count = counts[key, default: 0] - 1
        counts[key] = count > 0 ? count : nil
        onChange?()
    }
}

/// Kürzen-Fenster (Figma-Rahmen 5): `AVPlayerView` im Trim-Modus, danach die Leiste mit Bereich,
/// Länge, geschätzter Größe, „Original ersetzen“, „Als GIF …“, „Abbrechen“ und „Sichern“.
@MainActor
enum TrimWindow {
    /// Bekommt jede neue Datei (gekürztes Video oder GIF), damit eine Karte erscheint.
    static var onResult: ((RecordingResult) -> Void)?

    private static var controllers: [URL: TrimWindowController] = [:]

    static func show(url: URL) {
        let key = url.standardizedFileURL
        NSApp.activate()
        if let existing = controllers[key] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = TrimWindowController(url: key)
        controller.onClose = { controllers[key] = nil }
        controllers[key] = controller
        controller.start()
    }
}

/// Zustand der Leiste unter dem Player.
@MainActor @Observable
final class TrimBarModel {
    var start: Double = 0
    var end: Double = 0
    var fileSize: Int64 = 0
    var totalDuration: Double = 0
    var replaceOriginal = false
    var isWorking = false

    var length: Double { max(0, end - start) }

    /// Proportional geschätzt: Dateigröße × Auswahl / Gesamtdauer.
    var estimatedSize: Int64 {
        guard totalDuration > 0 else { return fileSize }
        return Int64(Double(fileSize) * min(1, length / totalDuration))
    }

    var info: String {
        let from = VideoText.duration(start, padMinutes: true)
        let to = VideoText.duration(end, padMinutes: true)
        let length = VideoText.duration(length, padMinutes: true)
        let size = VideoText.size(estimatedSize)
        return String(localized: "Auswahl \(from) – \(to) · Länge \(length) · ≈ \(size)")
    }
}

struct TrimBarActions {
    var gif: () -> Void
    var cancel: () -> Void
    var save: () -> Void
}

struct TrimBarView: View {
    @Bindable var model: TrimBarModel
    let actions: TrimBarActions

    var body: some View {
        HStack(spacing: 12) {
            Text(model.info)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 12)
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Toggle("Original ersetzen", isOn: $model.replaceOriginal)
                .toggleStyle(.checkbox)
                .disabled(model.isWorking)
            Button("Als GIF …", action: actions.gif)
                .disabled(model.isWorking)
            Button("Abbrechen", action: actions.cancel)
                .keyboardShortcut(.cancelAction)
            Button("Sichern", action: actions.save)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

@MainActor
final class TrimWindowController: NSObject, NSWindowDelegate {
    private static let logger = Logger(subsystem: "com.screenx.app", category: "trim")

    let window: NSWindow
    var onClose: (() -> Void)?

    private let url: URL
    private let player: AVPlayer
    private let playerView: AVPlayerView
    private let model: TrimBarModel
    private let bar: NSHostingView<TrimBarView>
    private var displaySize: CGSize = .zero
    private var job: Task<Void, Never>?
    private var gifSheet: GIFExportSheet?
    private var isClosed = false

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        playerView = AVPlayerView()
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let model = TrimBarModel()
        self.model = model
        // Vorläufige Aktionen; nach `super.init` durch die echten ersetzt.
        bar = NSHostingView(rootView: TrimBarView(model: model, actions: TrimBarActions(gif: {}, cancel: {}, save: {})))
        super.init()
        bar.rootView = TrimBarView(model: model, actions: TrimBarActions(
            gif: { [weak self] in self?.showGIFSheet() },
            cancel: { [weak self] in self?.cancel() },
            save: { [weak self] in self?.save() }
        ))
        window.title = url.lastPathComponent
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 640, height: 400)
        window.delegate = self

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        bar.isHidden = true

        let stack = NSStackView(views: [playerView, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.distribution = .fill
        playerView.setContentHuggingPriority(.defaultLow, for: .vertical)
        bar.setContentHuggingPriority(.required, for: .vertical)
        window.contentView = stack
        window.center()
    }

    func start() {
        window.makeKeyAndOrderFront(nil)
        model.fileSize = VideoFileInfo.fileSize(url)
        Task { [weak self, url] in
            let info = await VideoFileInfo.info(url: url)
            guard let self, !self.isClosed else { return }
            if let info {
                self.displaySize = info.displaySize
                self.model.totalDuration = info.duration
                self.model.end = info.duration
                self.fitWindow(to: info.displaySize)
            }
            await self.beginTrimming()
        }
    }

    /// Passt das Fenster an das Seitenverhältnis des Videos an (höchstens 80 % des Bildschirms), damit
    /// neben dem Bild keine großen leeren Flächen bleiben. Platz für die Player-Leiste und die Kürzen-Leiste
    /// kommt unten dazu.
    private func fitWindow(to videoSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0,
              let screen = window.screen ?? NSScreen.main else { return }
        let controls: CGFloat = 120
        let limit = screen.visibleFrame.size
        let maxVideo = CGSize(width: limit.width * 0.8, height: limit.height * 0.8 - controls)
        let scale = min(1, maxVideo.width / videoSize.width, maxVideo.height / videoSize.height)
        var content = CGSize(width: (videoSize.width * scale).rounded(), height: (videoSize.height * scale).rounded() + controls)
        content.width = max(content.width, window.minSize.width)
        content.height = max(content.height, window.minSize.height)
        window.setContentSize(content)
        window.center()
    }

    /// Wartet, bis der Player bereit ist, und startet den Trim-Modus. Geht das nicht, erscheint die
    /// Leiste mit dem ganzen Video.
    private func beginTrimming() async {
        var attempts = 0
        while player.currentItem?.status != .readyToPlay, attempts < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            if isClosed { return }
            attempts += 1
        }
        guard playerView.canBeginTrimming else {
            Self.logger.error("Trim-Modus nicht verfügbar: \(self.url.lastPathComponent, privacy: .public)")
            showBar()
            return
        }
        let result = await playerView.beginTrimming()
        guard !isClosed else { return }
        switch result {
        case .okButton:
            if let item = player.currentItem {
                let start = item.reversePlaybackEndTime
                let end = item.forwardPlaybackEndTime
                if start.isNumeric { model.start = max(0, start.seconds) }
                if end.isNumeric, end.seconds > model.start {
                    model.end = model.totalDuration > 0 ? min(model.totalDuration, end.seconds) : end.seconds
                }
            }
            showBar()
        default:
            window.close()
        }
    }

    private func showBar() {
        bar.isHidden = false
    }

    // MARK: - Aktionen

    private func cancel() {
        if let job {
            job.cancel()
        } else {
            window.close()
        }
    }

    private func save() {
        guard job == nil, gifSheet == nil, model.length > 0 else { return }
        let source = url
        let destination = TrimExporter.trimmedURL(for: source)
        let start = model.start
        let end = model.end
        let replace = model.replaceOriginal
        model.isWorking = true
        VideoJobs.shared.begin(source)
        job = Task { [weak self] in
            defer { VideoJobs.shared.end(source) }
            do {
                try await VideoFileInfo.exportTrim(source: source, start: start, end: end, to: destination)
            } catch is CancellationError {
                self?.finishJob()
                return
            } catch {
                Self.logger.error("Kürzen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                self?.finishJob()
                self?.showError(String(localized: "Kürzen fehlgeschlagen"), detail: error.localizedDescription)
                return
            }
            // Cancelled (or window closed) after the export finished: keep the original, drop the new file.
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: destination)
                self?.finishJob()
                return
            }
            var result = destination
            if replace {
                // Der Player hält die Datei offen: vorher freigeben.
                self?.player.replaceCurrentItem(with: nil)
                do {
                    result = try Self.replace(source, with: destination)
                } catch {
                    Self.logger.error("Ersetzen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                    // Modal statt als Blatt, weil das Fenster gleich danach schließt.
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = String(
                        localized: "Das Original konnte nicht ersetzt werden. Die gekürzte Datei heißt „\(destination.lastPathComponent)“."
                    )
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
            TrimWindow.onResult?(RecordingResult(
                url: result, duration: (await VideoFileInfo.info(url: result))?.duration ?? end - start,
                size: VideoFileInfo.fileSize(result), warnings: []
            ))
            self?.finishJob()
            self?.window.close()
        }
    }

    /// Legt das Original in den Papierkorb und benennt die neue Datei auf den Originalnamen um.
    /// Schlägt das Umbenennen fehl, bleibt die neue Datei unter ihrem Namen (das Original liegt im Papierkorb).
    private static func replace(_ original: URL, with trimmed: URL) throws -> URL {
        try FileManager.default.trashItem(at: original, resultingItemURL: nil)
        try FileManager.default.moveItem(at: trimmed, to: original)
        return original
    }

    private func finishJob() {
        job = nil
        model.isWorking = false
    }

    private func showGIFSheet() {
        guard job == nil, gifSheet == nil, model.length > 0 else { return }
        let sheet = GIFExportSheet(
            source: url, start: model.start, end: model.end, sourceSize: displaySize
        ) { [weak self] result in
            self?.gifSheet = nil
            if let result { TrimWindow.onResult?(result) }
        }
        gifSheet = sheet
        sheet.begin(on: window)
    }

    private func showError(_ title: String, detail: String) {
        guard !isClosed else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        job?.cancel()
        gifSheet?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        onClose?()
    }
}
