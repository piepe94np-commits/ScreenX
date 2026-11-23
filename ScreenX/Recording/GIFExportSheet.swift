import AppKit
import OSLog
import ScreenXCore
import SwiftUI

/// Breite im GIF-Blatt; `nil` = Originalbreite.
enum GIFWidthChoice: Int, CaseIterable, Identifiable {
    case original = 0
    case w800 = 800
    case w640 = 640
    case w480 = 480
    case w320 = 320

    var id: Int { rawValue }
    var pixels: Int? { self == .original ? nil : rawValue }

    var label: String {
        self == .original ? String(localized: "Original") : "\(rawValue)"
    }
}

/// Zustand des Blatts „Als GIF exportieren“ (Figma-Rahmen 5b).
@MainActor @Observable
final class GIFExportModel {
    static let fpsChoices = [15, 10, 8]
    static let warningMegabytes = 25.0

    var width: GIFWidthChoice = .w640
    var fps = 10
    var loops = true
    /// `nil`: es läuft kein Export.
    var progress: Double?

    let sourceSize: CGSize
    let seconds: Double

    init(sourceSize: CGSize, seconds: Double) {
        self.sourceSize = sourceSize
        self.seconds = seconds
    }

    var options: GIFOptions { GIFOptions(width: width.pixels, fps: fps, loops: loops) }

    /// Ausgabegröße wie beim Encoder: nie größer als die Quelle, Seitenverhältnis bleibt.
    var outputSize: CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let width = min(CGFloat(self.width.pixels ?? Int(sourceSize.width)), sourceSize.width)
        return CGSize(width: width, height: (width * sourceSize.height / sourceSize.width).rounded())
    }

    var megabytes: Double {
        RecordingEstimate.gifMegabytes(size: outputSize, fps: fps, seconds: seconds)
    }

    var isLarge: Bool { megabytes > Self.warningMegabytes }

    var estimateText: String {
        let value = VideoText.megabytes(megabytes)
        return isLarge
            ? String(localized: "⚠︎ ≈ \(value) MB – GIF wird groß. Kürzer, kleiner oder als Video teilen?")
            : String(localized: "≈ \(value) MB")
    }
}

struct GIFExportActions {
    var cancel: () -> Void
    var export: () -> Void
}

struct GIFExportView: View {
    @Bindable var model: GIFExportModel
    let actions: GIFExportActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Als GIF exportieren")
                .font(.system(size: 15, weight: .semibold))
            row("Breite") {
                Picker("Breite", selection: $model.width) {
                    ForEach(GIFWidthChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            }
            row("Bildrate") {
                Picker("Bildrate", selection: $model.fps) {
                    ForEach(GIFExportModel.fpsChoices, id: \.self) { fps in
                        Text(fps == 8 ? String(localized: "8 fps") : "\(fps)").tag(fps)
                    }
                }
            }
            HStack {
                Text("Endlosschleife")
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Endlosschleife", isOn: $model.loops)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text(model.estimateText)
                .font(.system(size: 12))
                .foregroundStyle(model.isLarge ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let progress = model.progress {
                ProgressView(value: progress)
            }
            HStack {
                Spacer()
                Button("Abbrechen", action: actions.cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Exportieren", action: actions.export)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.progress != nil)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            content()
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.progress != nil)
        }
    }
}

/// Blatt am Kürzen-Fenster: Optionen, Live-Schätzung, Fortschritt und Abbrechen.
/// `onFinished` bekommt das fertige GIF oder `nil` (abgebrochen oder fehlgeschlagen).
@MainActor
final class GIFExportSheet {
    private static let logger = Logger(subsystem: "com.screenx.app", category: "gif")

    private let source: URL
    private let start: Double
    private let end: Double
    private let model: GIFExportModel
    private let sheet: NSWindow
    private let onFinished: (RecordingResult?) -> Void
    private weak var parent: NSWindow?
    private var task: Task<Void, Never>?
    private var isDone = false

    init(
        source: URL, start: Double, end: Double, sourceSize: CGSize,
        onFinished: @escaping (RecordingResult?) -> Void
    ) {
        self.source = source
        self.start = start
        self.end = end
        self.onFinished = onFinished
        let model = GIFExportModel(sourceSize: sourceSize, seconds: end - start)
        self.model = model
        // Vorläufige Aktionen; unten durch die echten ersetzt.
        let controller = NSHostingController(
            rootView: GIFExportView(model: model, actions: GIFExportActions(cancel: {}, export: {}))
        )
        sheet = NSWindow(contentViewController: controller)
        controller.rootView = GIFExportView(model: model, actions: GIFExportActions(
            cancel: { [weak self] in self?.cancel() },
            export: { [weak self] in self?.export() }
        ))
    }

    func begin(on window: NSWindow) {
        parent = window
        window.beginSheet(sheet)
    }

    /// Bricht einen laufenden Export ab, sonst schließt das Blatt.
    func cancel() {
        if let task {
            task.cancel()
        } else {
            finish(nil)
        }
    }

    private func export() {
        guard task == nil, !isDone else { return }
        let source = source
        let start = start
        let end = end
        let options = model.options
        let destination = Self.gifURL(for: source)
        let model = model
        model.progress = 0
        VideoJobs.shared.begin(source)
        task = Task { [weak self] in
            defer { VideoJobs.shared.end(source) }
            do {
                try await VideoFileInfo.encodeGIF(
                    source: source, start: start, end: end, options: options, to: destination
                ) { value in
                    Task { @MainActor in
                        if model.progress != nil { model.progress = value }
                    }
                }
                self?.finish(RecordingResult(
                    url: destination, duration: end - start, size: VideoFileInfo.fileSize(destination), warnings: []
                ))
            } catch is CancellationError {
                self?.task = nil
                model.progress = nil
            } catch {
                Self.logger.error("GIF-Export fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                self?.task = nil
                model.progress = nil
                self?.showError(error)
            }
        }
    }

    private func finish(_ result: RecordingResult?) {
        guard !isDone else { return }
        isDone = true
        task = nil
        if let parent, parent.attachedSheet === sheet {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
        onFinished(result)
    }

    private func showError(_ error: Error) {
        guard !isDone else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "GIF-Export fehlgeschlagen")
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: sheet)
    }

    /// Gleicher Name wie die Quelle mit `.gif`; ist er belegt, „Name 2.gif“, „Name 3.gif“, …
    static func gifURL(for source: URL) -> URL {
        let directory = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let name = counter == 1 ? base : "\(base) \(counter)"
            let url = directory.appendingPathComponent(name).appendingPathExtension("gif")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            counter += 1
        }
    }
}
