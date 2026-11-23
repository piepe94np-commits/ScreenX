import AppKit
import CoreMedia
import Foundation
import Observation
import os
import ScreenCaptureKit
import ScreenXCore

enum RecordingState: Equatable {
    case idle
    /// `started` is when the recording began; it stays the same across pauses.
    case recording(started: Date)
    case paused
    case finishing
}

/// Why the engine ended a recording on its own (after a clean stop; `stop()` then returns its result).
enum RecordingStopReason: Equatable {
    case lowDisk
    case streamEnded(String)
    case writerFailed(String)
}

struct RecordingResult: Sendable {
    /// The finished `.mp4` or `.gif`; the `.mov` if finalizing failed (kept for recovery).
    var url: URL
    /// Recorded time without pauses.
    var duration: TimeInterval
    var size: Int64
    /// German notes for the user, e.g. a missing microphone or a failed conversion.
    var warnings: [String]
}

/// Records a display, an area or a window with ScreenCaptureKit into a `VideoFileWriter`, then finalizes the
/// file (`.mov` → `.mp4`, optionally → `.gif`).
///
/// Timing: the sample buffers' presentation times (host-time clock) go to the writer unchanged; pause, resume
/// and stop use the current host time, so all times come from the same clock.
@MainActor @Observable
final class RecordingEngine {
    private(set) var state: RecordingState = .idle
    /// Recorded time without pauses, refreshed every 0.5 s.
    private(set) var elapsed: TimeInterval = 0
    /// Size of the `.mov` so far, refreshed every 0.5 s.
    private(set) var bytesWritten: Int64 = 0

    /// Called after the engine stopped a recording on its own; call `stop()` to get that recording's result.
    @ObservationIgnored var onAutoStop: ((RecordingStopReason) -> Void)?

    /// Below this much free space a running recording is stopped.
    static let minimumFreeBytesWhileRecording: Int64 = 300_000_000
    private static let diskCheckInterval: TimeInterval = 10
    private static let tickInterval: TimeInterval = 0.5
    nonisolated private static let log = Logger(subsystem: "com.screenx.app", category: "recording")
    private static let notificationCenterBundleID = "com.apple.notificationcenterui"

    private let settings: () -> AppSettings
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var isStarting = false
    /// Set by `stop()`/`discard()` while `start` is still pending; `start` then tears down instead of recording.
    @ObservationIgnored private var startCancelled = false
    @ObservationIgnored private var isDiscarding = false
    /// The stop in progress or the last one; a later `stop()` (after an auto-stop) returns its result.
    @ObservationIgnored private var stopTask: Task<RecordingResult, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    private struct Session {
        let writer: VideoFileWriter
        let mov: URL
        let profile: RecordingProfile
        let directory: URL
        let started: Date
        let mainStream: SCStream
        var audioStream: SCStream?
        /// Kept alive here: the streams' output and delegate objects.
        let sinks: [StreamSink]
        var warnings: [String]
        /// Recorded time before the current active segment.
        var accumulated: TimeInterval = 0
        /// Start of the current active segment; nil while paused.
        var activeSince: Date?
        var loggedDrops = false
        var lastDiskCheck = Date()

        func elapsed(at now: Date) -> TimeInterval {
            accumulated + (activeSince.map { now.timeIntervalSince($0) } ?? 0)
        }
    }

    init(settings: @escaping () -> AppSettings) {
        self.settings = settings
    }

    // MARK: - Control

    /// Starts recording `target`. `includedWindowIDs` are ScreenX windows that belong in the video (click circles).
    /// A denied microphone is not an error: the recording runs without it and the result carries a warning.
    func start(target: RecordingTarget, profile: RecordingProfile, systemAudio: Bool, microphone: Bool,
               includedWindowIDs: [CGWindowID]) async throws {
        guard state == .idle, !isStarting else {
            throw CaptureError.failed(String(localized: "Es läuft bereits eine Aufnahme."))
        }
        isStarting = true
        startCancelled = false
        defer { isStarting = false }
        stopTask = nil
        elapsed = 0
        bytesWritten = 0

        let appSettings = self.settings()
        var warnings: [String] = []
        var useMicrophone = microphone
        if microphone, !(await MicrophonePermission.request()) {
            useMicrophone = false
            warnings.append(String(localized: "Das Mikrofon ist nicht freigegeben. Die Aufnahme läuft ohne Mikrofon."))
        }

        let directory = appSettings.saveDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }

        let source = try Self.source(for: target, content: content, hideNotifications: appSettings.hideNotifications,
                                     includedWindowIDs: includedWindowIDs)
        let size = RecordingEstimate.targetSize(source: source.pixelSize, resolution: profile.resolution)
        let isWindow = if case .window = target { true } else { false }
        let separateSystemAudio = systemAudio && isWindow
        let writerSettings = VideoWriterSettings(
            size: size, fps: profile.fps, codec: profile.codec,
            bitrate: RecordingEstimate.videoBitrate(size: size, fps: profile.fps, quality: profile.quality,
                                                    codec: profile.codec),
            audioTracks: (systemAudio ? 1 : 0) + (useMicrophone ? 1 : 0))

        let mov = RecordingNaming.movURL(in: directory, date: Date())
        let writer: VideoFileWriter
        do {
            writer = try VideoFileWriter(url: mov, settings: writerSettings)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }

        // Main stream: picture, plus system audio (display/area) and microphone.
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(profile.fps))
        // The writer's pixel buffer adaptor takes BGRA; sRGB shares the BT.709 primaries the writer tags.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        // A window that changes size is fitted into the fixed output size (letterboxed).
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.showsCursor = profile.showsCursor
        if let rect = source.sourceRect { config.sourceRect = rect }
        if isWindow { config.ignoreShadowsSingleWindow = true }
        Self.configureAudio(config, systemAudio: systemAudio && !isWindow)
        config.captureMicrophone = useMicrophone
        if useMicrophone { config.microphoneCaptureDeviceID = appSettings.microphoneDeviceID }

        let mainSink = StreamSink(writer: writer, role: .main, onStop: streamStopHandler(role: .main))
        let mainStream = SCStream(filter: source.filter, configuration: config, delegate: mainSink)
        var sinks = [mainSink]
        do {
            let queue = DispatchQueue(label: "com.screenx.app.recording.main")
            try mainStream.addStreamOutput(mainSink, type: .screen, sampleHandlerQueue: queue)
            if systemAudio && !isWindow {
                try mainStream.addStreamOutput(mainSink, type: .audio, sampleHandlerQueue: queue)
            }
            if useMicrophone {
                try mainStream.addStreamOutput(mainSink, type: .microphone, sampleHandlerQueue: queue)
            }
            try await Self.startCapture(mainStream)
        } catch {
            await Self.abandon(writer: writer, mov: mov)
            throw Self.map(error)
        }

        // Window mode: a window filter only carries its own app's sound, so system audio comes from a
        // second, audio-only stream over the display (without ScreenX). If it fails the recording goes on.
        var audioStream: SCStream?
        if separateSystemAudio, let display = source.audioDisplay {
            let audioConfig = SCStreamConfiguration()
            audioConfig.width = 2
            audioConfig.height = 2
            audioConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            audioConfig.showsCursor = false
            Self.configureAudio(audioConfig, systemAudio: true)
            let audioSink = StreamSink(writer: writer, role: .systemAudio,
                                       onStop: streamStopHandler(role: .systemAudio))
            let filter = CaptureService.displayFilterExcludingScreenX(display: display, content: content)
            let stream = SCStream(filter: filter, configuration: audioConfig, delegate: audioSink)
            do {
                let queue = DispatchQueue(label: "com.screenx.app.recording.system-audio")
                // A screen output avoids SCStream's "output not found" handling; its frames are ignored.
                try stream.addStreamOutput(audioSink, type: .screen, sampleHandlerQueue: queue)
                try stream.addStreamOutput(audioSink, type: .audio, sampleHandlerQueue: queue)
                try await Self.startCapture(stream)
                audioStream = stream
                sinks.append(audioSink)
            } catch {
                Self.log.error("System audio stream failed to start: \(error.localizedDescription, privacy: .public)")
                warnings.append(Self.systemAudioFailedWarning)
            }
        } else if separateSystemAudio {
            warnings.append(Self.systemAudioFailedWarning)
        }

        let now = Date()
        session = Session(writer: writer, mov: mov, profile: profile, directory: directory, started: now,
                          mainStream: mainStream, audioStream: audioStream, sinks: sinks, warnings: warnings,
                          activeSince: now, lastDiskCheck: now)
        if startCancelled, let session {
            // stop() or discard() came while the start was pending: tear down instead of recording.
            await Self.stopStreams(session)
            await Self.abandon(writer: session.writer, mov: session.mov)
            self.session = nil
            throw CancellationError()
        }
        writer.onFailure = { [weak self] error in
            let text = error.localizedDescription
            Task { @MainActor in self?.autoStop(.writerFailed(text)) }
        }
        state = .recording(started: now)
        startTicker()
    }

    func pause() {
        guard case .recording = state, var session else { return }
        session.writer.pause(at: Self.hostNow())
        let now = Date()
        session.accumulated = session.elapsed(at: now)
        session.activeSince = nil
        self.session = session
        elapsed = session.accumulated
        state = .paused
    }

    func resume() {
        guard state == .paused, var session else { return }
        session.writer.resume(at: Self.hostNow())
        session.activeSince = Date()
        self.session = session
        state = .recording(started: session.started)
    }

    /// Stops the streams, finishes the `.mov` and finalizes it. After an auto-stop this returns the result of
    /// that stop. Never throws: problems end up in `warnings` (with no picture at all the `.mov` may be missing).
    func stop() async -> RecordingResult {
        if let stopTask { return await stopTask.value }
        // No recording, a start still pending (it is cancelled) or a discard in progress: nothing to save.
        guard session != nil, !isDiscarding else {
            if isStarting { startCancelled = true }
            return RecordingResult(url: settings().saveDirectory, duration: 0, size: 0,
                                   warnings: [String(localized: "Es läuft keine Aufnahme.")])
        }
        let task = Task { await self.performStop() }
        stopTask = task
        return await task.value
    }

    /// Stops everything and deletes the recording.
    func discard() async {
        guard stopTask == nil, !isDiscarding, let session else {
            if isStarting { startCancelled = true }
            return
        }
        isDiscarding = true
        defer { isDiscarding = false }
        state = .finishing
        stopTicker()
        await Self.stopStreams(session)
        await Self.abandon(writer: session.writer, mov: session.mov)
        self.session = nil
        elapsed = 0
        bytesWritten = 0
        state = .idle
    }

    /// Free space for important data on the volume of `url`, in bytes.
    nonisolated static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Stopping

    private func performStop() async -> RecordingResult {
        guard let session else {
            return RecordingResult(url: settings().saveDirectory, duration: 0, size: 0, warnings: [])
        }
        let stopTime = Self.hostNow()
        let duration = session.elapsed(at: Date())
        state = .finishing
        stopTicker()
        elapsed = duration
        await Self.stopStreams(session)

        var warnings = session.warnings
        let writer = session.writer
        var wroteFrames = true
        do {
            _ = try await writer.finish(stopAt: stopTime)
        } catch {
            // The fragmented .mov may still hold everything up to the last fragment; try to finalize it anyway.
            warnings.append(error.localizedDescription)
            if !writer.hasWrittenVideo {
                // Nothing was recorded: remove the stub instead of finalizing it into a second error.
                wroteFrames = false
                try? FileManager.default.removeItem(at: session.mov)
            }
        }
        if writer.droppedAudioBuffers > 0 {
            let count = writer.droppedAudioBuffers
            warnings.append(String(localized: "Ein Teil des Tons ging verloren (\(count) Abschnitte)."))
        }

        var url = session.mov
        if wroteFrames, FileManager.default.fileExists(atPath: session.mov.path) {
            do {
                url = try await RecordingFinalizer.finalize(mov: session.mov)
                if session.profile.output == .gif {
                    url = await Self.convertToGIF(mp4: url, fps: session.profile.fps, warnings: &warnings)
                }
            } catch {
                warnings.append(String(localized:
                    "Die MP4-Datei konnte nicht erstellt werden, die MOV-Datei bleibt erhalten: \(error.localizedDescription)"))
            }
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        self.session = nil
        bytesWritten = size
        state = .idle
        return RecordingResult(url: url, duration: duration, size: size, warnings: warnings)
    }

    /// Converts the finished `.mp4` into a `.gif` with the same base name and deletes the `.mp4`.
    /// If the conversion fails the `.mp4` is kept and returned.
    private static func convertToGIF(mp4: URL, fps: Int, warnings: inout [String]) async -> URL {
        let gif = mp4.deletingPathExtension().appendingPathExtension("gif")
        do {
            try await GIFEncoder.encode(source: mp4, range: nil, options: GIFOptions(width: nil, fps: fps, loops: true),
                                        to: gif, progress: { _ in })
            try? FileManager.default.removeItem(at: mp4)
            return gif
        } catch {
            warnings.append(String(localized:
                "Das GIF konnte nicht erstellt werden, das Video bleibt erhalten: \(error.localizedDescription)"))
            return mp4
        }
    }

    /// Stops the recording cleanly, then reports why.
    private func autoStop(_ reason: RecordingStopReason) {
        guard session != nil, stopTask == nil, state != .finishing else { return }
        Self.log.notice("Recording stopped automatically: \(String(describing: reason), privacy: .public)")
        Task {
            _ = await stop()
            onAutoStop?(reason)
        }
    }

    private func systemAudioStreamEnded(_ text: String) {
        guard var session, session.audioStream != nil else { return }
        Self.log.error("System audio stream stopped: \(text, privacy: .public)")
        session.audioStream = nil
        session.warnings.append(String(localized: "Der Systemton ist ausgefallen. Die Aufnahme lief ohne Systemton weiter."))
        self.session = session
    }

    private func streamStopHandler(role: StreamSink.Role) -> @Sendable (String) -> Void {
        { [weak self] text in
            Task { @MainActor in
                switch role {
                case .main: self?.autoStop(.streamEnded(text))
                case .systemAudio: self?.systemAudioStreamEnded(text)
                }
            }
        }
    }

    // MARK: - Ticker (elapsed, size, drops, disk space)

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickInterval))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard var session, state != .finishing else { return }
        let now = Date()
        elapsed = session.elapsed(at: now)
        bytesWritten = session.writer.bytesWritten
        if !session.loggedDrops, elapsed >= 1 {
            session.loggedDrops = true
            let video = session.writer.droppedVideoFrames
            let audio = session.writer.droppedAudioBuffers
            if video > 0 || audio > 0 {
                Self.log.notice("Dropped after 1 s: \(video, privacy: .public) video frames, \(audio, privacy: .public) audio buffers")
            }
        }
        var lowDisk = false
        if now.timeIntervalSince(session.lastDiskCheck) >= Self.diskCheckInterval {
            session.lastDiskCheck = now
            if let free = Self.freeSpace(at: session.directory), free < Self.minimumFreeBytesWhileRecording {
                lowDisk = true
            }
        }
        self.session = session
        if lowDisk { autoStop(.lowDisk) }
    }

    // MARK: - Helpers

    private struct Source {
        let filter: SCContentFilter
        let pixelSize: CGSize
        let sourceRect: CGRect?
        /// Display for the audio-only stream in window mode.
        let audioDisplay: SCDisplay?
    }

    private static func source(for target: RecordingTarget, content: SCShareableContent, hideNotifications: Bool,
                               includedWindowIDs: [CGWindowID]) throws -> Source {
        let hidden: Set<String> = hideNotifications ? [notificationCenterBundleID] : []
        switch target {
        case .display(let id), .area(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.displayNotFound
            }
            let filter = CaptureService.displayFilterExcludingScreenX(
                display: display, content: content, exceptingWindowIDs: includedWindowIDs, excludingBundleIDs: hidden)
            let scale = CGFloat(filter.pointPixelScale)
            if case .area(_, let rect) = target {
                return Source(filter: filter, pixelSize: CGSize(width: rect.width * scale, height: rect.height * scale),
                              sourceRect: rect, audioDisplay: nil)
            }
            return Source(filter: filter,
                          pixelSize: CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale),
                          sourceRect: nil, audioDisplay: nil)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.windowNotFound
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            // pointPixelScale is the backing scale factor of the window's display.
            let scale = CGFloat(filter.pointPixelScale)
            let display = content.displays.first { $0.frame.intersects(window.frame) } ?? content.displays.first
            return Source(filter: filter,
                          pixelSize: CGSize(width: window.frame.width * scale, height: window.frame.height * scale),
                          sourceRect: nil, audioDisplay: display)
        }
    }

    private static func configureAudio(_ config: SCStreamConfiguration, systemAudio: Bool) {
        config.capturesAudio = systemAudio
        config.sampleRate = VideoWriterSettings.audioSampleRate
        config.channelCount = VideoWriterSettings.audioChannels
        config.excludesCurrentProcessAudio = true
    }

    private static var systemAudioFailedWarning: String {
        String(localized: "Der Systemton konnte nicht aufgenommen werden. Die Aufnahme läuft ohne Systemton.")
    }

    private static func hostNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private static func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func stopCapture(_ stream: SCStream) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stream.stopCapture { @Sendable error in
                if let error {
                    log.error("Stopping a stream failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume()
            }
        }
    }

    private static func stopStreams(_ session: Session) async {
        await stopCapture(session.mainStream)
        if let audio = session.audioStream { await stopCapture(audio) }
    }

    /// Ends the writer without keeping anything and deletes the `.mov`.
    private static func abandon(writer: VideoFileWriter, mov: URL) async {
        _ = try? await writer.finish(stopAt: hostNow())
        try? FileManager.default.removeItem(at: mov)
    }

    private static func map(_ error: any Error) -> CaptureError {
        if let error = error as? CaptureError { return error }
        if let error = error as? SCStreamError, error.code == .userDeclined { return .permissionDenied }
        return .failed(error.localizedDescription)
    }
}

/// Receives the sample buffers of one `SCStream` on its sample-handler queue and hands them to the writer.
/// Immutable and made of Sendable parts, so it is Sendable without `@unchecked`.
private final class StreamSink: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    enum Role: Sendable {
        /// Picture, plus system audio and microphone if configured.
        case main
        /// Window mode's audio-only stream: its frames are ignored.
        case systemAudio
    }

    let writer: VideoFileWriter
    let role: Role
    let onStop: @Sendable (String) -> Void

    init(writer: VideoFileWriter, role: Role, onStop: @escaping @Sendable (String) -> Void) {
        self.writer = writer
        self.role = role
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard role == .main, Self.isComplete(sampleBuffer),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            writer.appendVideo(pixelBuffer, hostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        case .audio:
            writer.appendAudio(sampleBuffer, track: .system)
        case .microphone:
            writer.appendAudio(sampleBuffer, track: .microphone)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop(error.localizedDescription)
    }

    /// Only frames with new content are written (idle, blank or suspended frames carry no picture).
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
