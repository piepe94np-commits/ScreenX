import AVFoundation
import CoreMedia
import CoreVideo
import os

public enum AudioTrackKind: Sendable {
    case system, microphone
}

public enum VideoWriterError: Error, Equatable, Sendable {
    case cannotCreate
    case writerFailed(String)
}

extension VideoWriterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotCreate:
            String(localized: "Die Videodatei konnte nicht angelegt werden.")
        case .writerFailed(let reason):
            String(localized: "Das Video konnte nicht geschrieben werden: \(reason)")
        }
    }
}

/// Writes captured frames and audio into a fragmented QuickTime movie (`.mov`).
///
/// Host times (as delivered by ScreenCaptureKit) are mapped to file times through a `RecordingTimeline`:
/// the first video frame is time zero and pauses are cut out. Buffers that arrive while an input is not
/// ready are dropped and counted, never waited for. Because `movieFragmentInterval` is set before
/// writing starts, the file stays readable up to its last fragment even if `finish` is never called.
/// Every audio buffer is converted to interleaved float32 48 kHz stereo before it reaches the encoder.
///
/// `@unchecked Sendable`: every access to the writer, its inputs and the mutable state below happens on
/// the private serial `queue`; public methods only enqueue work there or read state with `queue.sync`.
public final class VideoFileWriter: @unchecked Sendable {
    public let url: URL
    public let settings: VideoWriterSettings
    /// Whether the peak data-rate limit (see `VideoWriterSettings.peakBitrateFactor`) was requested from
    /// the encoder. Requested, not guaranteed honoured: some encoders accept the key but exceed the limit.
    public let usesDataRateLimit: Bool

    private static let log = Logger(subsystem: "com.screenx.app", category: "VideoFileWriter")
    private let queue = DispatchQueue(label: "com.screenx.app.video-writer")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInputs: [AVAssetWriterInput]

    // Queue-confined state.
    private var timeline = RecordingTimeline()
    private var sessionStarted = false
    private var lastVideoTime: CMTime?
    private var normalizers: [AudioNormalizer]
    private var lastDropLog: UInt64?
    private var finishing = false
    private var failureHandler: (@Sendable (VideoWriterError) -> Void)?
    private var failureReported = false

    /// Counters and failure, written on the queue and readable from any thread without waiting on it.
    private struct Statistics {
        var droppedVideoFrames = 0
        var droppedAudioBuffers = 0
        var failure: VideoWriterError?
    }
    private let statistics = OSAllocatedUnfairLock(initialState: Statistics())

    public init(url: URL, settings: VideoWriterSettings) throws {
        self.url = url
        self.settings = settings
        // Prefer a hard peak data rate so files never get much bigger than the estimate; fall back to the
        // average bit rate alone if the encoder rejects the limit or fails to start with it.
        let existedBefore = FileManager.default.fileExists(atPath: url.path)
        let parts: Parts
        if let limited = try? Self.makeWriter(url: url, settings: settings, dataRateLimit: true) {
            parts = limited
            usesDataRateLimit = true
        } else {
            if !existedBefore { try? FileManager.default.removeItem(at: url) }
            parts = try Self.makeWriter(url: url, settings: settings, dataRateLimit: false)
            usesDataRateLimit = false
        }
        writer = parts.writer
        videoInput = parts.video
        adaptor = parts.adaptor
        audioInputs = parts.audio
        normalizers = parts.audio.map { _ in AudioNormalizer() }
    }

    private struct Parts {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audio: [AVAssetWriterInput]
    }

    /// Creates the writer with all inputs and starts writing; throws `.cannotCreate` on any failure.
    private static func makeWriter(url: URL, settings: VideoWriterSettings, dataRateLimit: Bool) throws -> Parts {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw VideoWriterError.cannotCreate
        }
        writer.movieFragmentInterval = CMTime(
            seconds: VideoWriterSettings.fragmentIntervalSeconds, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let videoSettings = settings.videoOutputSettings(dataRateLimit: dataRateLimit)
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw VideoWriterError.cannotCreate
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw VideoWriterError.cannotCreate }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(settings.size.width),
                kCVPixelBufferHeightKey as String: Int(settings.size.height),
            ])

        let audioSettings = settings.audioOutputSettings
        var audio: [AVAssetWriterInput] = []
        for _ in 0..<settings.audioTracks {
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw VideoWriterError.cannotCreate
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw VideoWriterError.cannotCreate }
            writer.add(input)
            audio.append(input)
        }
        guard writer.startWriting() else { throw VideoWriterError.cannotCreate }
        return Parts(writer: writer, video: video, adaptor: adaptor, audio: audio)
    }

    // The getters below read a lock-protected mirror or the file system, never waiting on the writer
    // queue, so the UI may poll them.

    /// Current size of the output file in bytes.
    public var bytesWritten: Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return size?.int64Value ?? 0
    }

    /// Video frames dropped because the input was not ready for more data.
    public var droppedVideoFrames: Int { statistics.withLock { $0.droppedVideoFrames } }

    /// Audio buffers dropped: input not ready, fully covered by earlier output, or not convertible.
    public var droppedAudioBuffers: Int { statistics.withLock { $0.droppedAudioBuffers } }

    /// The first failure of the underlying writer during recording: its status left `.writing` or an
    /// append failed. A status change is detected on the next append. Errors of `finish` are only thrown.
    public var failure: VideoWriterError? { statistics.withLock { $0.failure } }

    /// Called once, on a background queue, when `failure` is first set (failures during recording only;
    /// `finish` throws instead). Getting or setting it synchronises with the writer queue.
    public var onFailure: (@Sendable (VideoWriterError) -> Void)? {
        get { queue.sync { failureHandler } }
        set {
            queue.sync {
                failureHandler = newValue
                reportFailureIfNeeded()
            }
        }
    }

    /// Appends a frame. The pixel buffer must have exactly `settings.size` (Task 7 configures
    /// ScreenCaptureKit's width and height to match); other sizes are a programming error.
    public func appendVideo(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime) {
        assert(CVPixelBufferGetWidth(pixelBuffer) == Int(settings.size.width)
               && CVPixelBufferGetHeight(pixelBuffer) == Int(settings.size.height),
               "pixel buffer size must equal VideoWriterSettings.size")
        let box = HandedOver(value: pixelBuffer)
        queue.async { self.writeVideo(box.value, hostTime: hostTime) }
    }

    /// Appends an audio buffer (any linear PCM format) to the track of `track`. With a single audio
    /// track, every source goes to that track (only one source is active then).
    public func appendAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrackKind) {
        let box = HandedOver(value: sampleBuffer)
        queue.async { self.writeAudio(box.value, track: track) }
    }

    public func pause(at hostTime: CMTime) {
        queue.async { self.timeline.pause(at: hostTime) }
    }

    public func resume(at hostTime: CMTime) {
        queue.async { self.timeline.resume(at: hostTime) }
    }

    /// Ends the session at the stop time (so the last frame is held until then) and finishes the file.
    public func finish(stopAt hostTime: CMTime) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async { self.finishOnQueue(stopAt: hostTime, continuation: continuation) }
        }
    }

    /// Audio timing corrections summed over all tracks (for tests and diagnostics).
    var audioTimingCorrections: (resyncs: Int, silenceFrames: Int, trimmedFrames: Int) {
        queue.sync {
            normalizers.reduce((0, 0, 0)) { ($0.0 + $1.resyncs, $0.1 + $1.silenceFrames, $0.2 + $1.trimmedFrames) }
        }
    }

    /// Test hook: cancels the underlying writer as if it had failed; detected on the next append.
    func simulateWriterFailureForTesting() {
        queue.sync { writer.cancelWriting() }
    }

    // MARK: - Queue-confined

    /// True while the writer accepts data; records a failure once its status has left `.writing`.
    private func isWritable() -> Bool {
        guard !finishing else { return false }
        guard writer.status == .writing else {
            recordFailure(writerError())
            return false
        }
        return true
    }

    private func writeVideo(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime) {
        guard isWritable(), let time = timeline.video(at: hostTime) else { return }
        if let lastVideoTime, CMTimeCompare(time, lastVideoTime) <= 0 { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else {
            statistics.withLock { $0.droppedVideoFrames += 1 }
            logDrop()
            return
        }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastVideoTime = time
        } else {
            recordFailure(writerError())
        }
    }

    private func writeAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrackKind) {
        guard !audioInputs.isEmpty, isWritable() else { return }
        let index = (track == .microphone && audioInputs.count > 1) ? 1 : 0
        let hostTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard hostTime.isValid else { return }
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if !duration.isValid { duration = .zero }
        guard let time = timeline.audio(at: hostTime, duration: duration), sessionStarted else { return }
        let input = audioInputs[index]
        guard input.isReadyForMoreMediaData else {
            dropAudio(track: index)
            return
        }
        switch normalizers[index].convert(sampleBuffer, at: time) {
        case .output(let silence, let converted, let start):
            // Silence before the data, in chunks of at most 1 s so memory stays bounded.
            var written = silence?.start ?? start
            for chunk in silence?.chunks() ?? [] {
                guard input.isReadyForMoreMediaData else {
                    dropAudio(track: index, writtenEnd: written)
                    return
                }
                guard let buffer = normalizers[index].silenceBuffer(chunk) else {
                    dropAudio(track: index, writtenEnd: written)
                    return
                }
                guard input.append(buffer) else {
                    recordFailure(writerError())
                    return
                }
                written = chunk.end
            }
            guard silence == nil || input.isReadyForMoreMediaData else {
                dropAudio(track: index, writtenEnd: written)
                return
            }
            if !input.append(converted) { recordFailure(writerError()) }
        case .empty:
            break
        case .covered, .failed:
            dropAudio(track: index)
        }
    }

    /// Counts and logs an audio drop and lets the track's normalizer resync on its next buffer.
    /// `writtenEnd` is the end of what was actually appended when a converted output was only partly written.
    private func dropAudio(track index: Int, writtenEnd: CMTime? = nil) {
        statistics.withLock { $0.droppedAudioBuffers += 1 }
        normalizers[index].noteDrop(writtenEnd: writtenEnd)
        logDrop()
    }

    private func finishOnQueue(stopAt hostTime: CMTime, continuation: CheckedContinuation<URL, Error>) {
        guard !finishing else {
            continuation.resume(throwing: VideoWriterError.writerFailed(
                String(localized: "Die Aufnahme wurde bereits beendet.")))
            return
        }
        guard writer.status == .writing else {
            finishing = true
            continuation.resume(throwing: writerError())
            return
        }
        finishing = true
        guard sessionStarted, let lastVideoTime else {
            writer.cancelWriting()
            continuation.resume(throwing: VideoWriterError.writerFailed(
                String(localized: "Es wurden keine Bilder aufgenommen.")))
            return
        }
        var end = timeline.outputTime(forStopAt: hostTime)
        if CMTimeCompare(end, lastVideoTime) < 0 { end = lastVideoTime }
        writer.endSession(atSourceTime: end)
        videoInput.markAsFinished()
        audioInputs.forEach { $0.markAsFinished() }
        writer.finishWriting {
            self.queue.async {
                if self.writer.status == .completed {
                    continuation.resume(returning: self.url)
                } else {
                    continuation.resume(throwing: self.writerError())
                }
            }
        }
    }

    private func writerError() -> VideoWriterError {
        .writerFailed(writer.error?.localizedDescription ?? String(localized: "Unbekannter Fehler"))
    }

    private func recordFailure(_ error: VideoWriterError) {
        let isFirst = statistics.withLock { stats in
            guard stats.failure == nil else { return false }
            stats.failure = error
            return true
        }
        guard isFirst else { return }
        Self.log.error("Writer failed: \(error.localizedDescription, privacy: .public)")
        reportFailureIfNeeded()
    }

    private func reportFailureIfNeeded() {
        guard !failureReported, let error = statistics.withLock({ $0.failure }), let handler = failureHandler else { return }
        failureReported = true
        DispatchQueue.global().async { handler(error) }
    }

    /// Logs dropped buffers at most once per second.
    private func logDrop() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let lastDropLog, now - lastDropLog < 1_000_000_000 { return }
        lastDropLog = now
        let stats = statistics.withLock { $0 }
        Self.log.notice(
            "Dropped buffers so far: \(stats.droppedVideoFrames, privacy: .public) video, \(stats.droppedAudioBuffers, privacy: .public) audio")
    }
}

/// Carries a capture buffer onto the writer queue. `@unchecked Sendable` is sound because the caller
/// hands the buffer over and neither side mutates its contents afterwards.
private struct HandedOver<Value>: @unchecked Sendable {
    let value: Value
}
