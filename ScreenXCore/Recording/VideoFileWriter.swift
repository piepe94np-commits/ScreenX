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
    private var audioEnds: [CMTime?]
    private var normalizers: [AudioNormalizer]
    private var videoDrops = 0
    private var audioDrops = 0
    private var lastDropLog: UInt64?
    private var finishing = false
    private var recordedFailure: VideoWriterError?
    private var failureHandler: (@Sendable (VideoWriterError) -> Void)?
    private var failureReported = false

    public init(url: URL, settings: VideoWriterSettings) throws {
        self.url = url
        self.settings = settings
        // Prefer a hard peak data rate so files never get much bigger than the estimate; fall back to the
        // average bit rate alone if the encoder rejects the limit or fails to start with it.
        let parts: Parts
        if let limited = try? Self.makeWriter(url: url, settings: settings, dataRateLimit: true) {
            parts = limited
            usesDataRateLimit = true
        } else {
            try? FileManager.default.removeItem(at: url)
            parts = try Self.makeWriter(url: url, settings: settings, dataRateLimit: false)
            usesDataRateLimit = false
        }
        writer = parts.writer
        videoInput = parts.video
        adaptor = parts.adaptor
        audioInputs = parts.audio
        audioEnds = Array(repeating: nil, count: parts.audio.count)
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

    /// Current size of the output file in bytes.
    public var bytesWritten: Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return size?.int64Value ?? 0
    }

    /// Video frames dropped because the input was not ready for more data.
    public var droppedVideoFrames: Int { queue.sync { videoDrops } }

    /// Audio buffers dropped: input not ready, overlapping a previous buffer, or not convertible.
    public var droppedAudioBuffers: Int { queue.sync { audioDrops } }

    /// The first failure of the underlying writer (status left `.writing`, or an append failed).
    public var failure: VideoWriterError? { queue.sync { recordedFailure } }

    /// Called once, on a background queue, when `failure` is first set.
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
            videoDrops += 1
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
        // A buffer that straddled a pause start overlaps the first one after resuming; small overlaps
        // (up to half a buffer) are absorbed by the normalizer's continuous output timing.
        if let end = audioEnds[index],
           CMTimeCompare(time, CMTimeSubtract(end, CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2))) < 0 {
            audioDrops += 1
            logDrop()
            return
        }
        let input = audioInputs[index]
        guard input.isReadyForMoreMediaData else {
            audioDrops += 1
            logDrop()
            return
        }
        guard let converted = normalizers[index].convert(sampleBuffer, at: time) else {
            audioDrops += 1
            logDrop()
            return
        }
        audioEnds[index] = CMTimeAdd(time, duration)
        if !input.append(converted) {
            recordFailure(writerError())
        }
    }

    private func finishOnQueue(stopAt hostTime: CMTime, continuation: CheckedContinuation<URL, Error>) {
        guard !finishing else {
            continuation.resume(throwing: VideoWriterError.writerFailed(
                String(localized: "Die Aufnahme wurde bereits beendet.")))
            return
        }
        guard writer.status == .writing else {
            finishing = true
            let error = writerError()
            recordFailure(error)
            continuation.resume(throwing: error)
            return
        }
        finishing = true
        guard sessionStarted, let lastVideoTime else {
            writer.cancelWriting()
            let error = VideoWriterError.writerFailed(String(localized: "Es wurden keine Bilder aufgenommen."))
            recordFailure(error)
            continuation.resume(throwing: error)
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
                    let error = self.writerError()
                    self.recordFailure(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writerError() -> VideoWriterError {
        .writerFailed(writer.error?.localizedDescription ?? String(localized: "Unbekannter Fehler"))
    }

    private func recordFailure(_ error: VideoWriterError) {
        guard recordedFailure == nil else { return }
        recordedFailure = error
        Self.log.error("Writer failed: \(error.localizedDescription, privacy: .public)")
        reportFailureIfNeeded()
    }

    private func reportFailureIfNeeded() {
        guard !failureReported, let error = recordedFailure, let handler = failureHandler else { return }
        failureReported = true
        DispatchQueue.global().async { handler(error) }
    }

    /// Logs dropped buffers at most once per second.
    private func logDrop() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let lastDropLog, now - lastDropLog < 1_000_000_000 { return }
        lastDropLog = now
        Self.log.notice(
            "Dropped buffers so far: \(self.videoDrops, privacy: .public) video, \(self.audioDrops, privacy: .public) audio")
    }
}

/// Converts one track's incoming audio (any linear PCM format, possibly changing mid-stream, e.g. after
/// a microphone switch) to interleaved float32 48 kHz stereo with continuous output timestamps.
/// Confined to the writer queue.
private final class AudioNormalizer {
    private let outputFormat = VideoWriterSettings.normalizedAudioFormat()
    private var converter: AVAudioConverter?
    private var inputDescription: CMFormatDescription?
    private var inputFormat: AVAudioFormat?
    /// Output time right after the last converted buffer.
    private var nextTime: CMTime?
    /// Beyond this gap between expected and actual input time the stream restarts (dropped buffers).
    private static let resyncThreshold = CMTime(value: 50, timescale: 1000)

    /// Converts `sampleBuffer`, whose start maps to output time `time`; `nil` if it cannot be converted.
    func convert(_ sampleBuffer: CMSampleBuffer, at time: CMTime) -> CMSampleBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        if inputDescription.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: description) }) ?? true {
            guard let format = Self.audioFormat(of: description),
                  let converter = AVAudioConverter(from: format, to: outputFormat) else {
                return nil
            }
            converter.primeMethod = .none
            converter.downmix = format.channelCount > outputFormat.channelCount
            self.converter = converter
            // `nextTime` is kept, so output stays continuous across a format change.
            inputFormat = format
            inputDescription = description
        }
        guard let converter, let inputFormat else { return nil }
        if let expected = nextTime,
           CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(time, expected)), Self.resyncThreshold) > 0 {
            converter.reset()
            nextTime = nil
        }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else {
            return nil
        }
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr
        else { return nil }
        input.frameLength = frames

        let capacity = AVAudioFrameCount(
            (Double(frames) * outputFormat.sampleRate / inputFormat.sampleRate).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        let pending = PendingInput(buffer: input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let buffer = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }

        let start = nextTime ?? time
        nextTime = CMTimeAdd(start, CMTime(value: CMTimeValue(output.frameLength),
                                           timescale: CMTimeScale(outputFormat.sampleRate)))
        return Self.sampleBuffer(from: output, at: start)
    }

    /// The input format; buffers with more than two channels and no layout get a discrete layout.
    private static func audioFormat(of description: CMAudioFormatDescription) -> AVAudioFormat? {
        guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = basic.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        var layoutSize = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize),
           layoutSize > 0 {
            return AVAudioFormat(streamDescription: &asbd, channelLayout: AVAudioChannelLayout(layout: layout))
        }
        if asbd.mChannelsPerFrame <= 2 {
            return AVAudioFormat(streamDescription: &asbd)
        }
        guard let discrete = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame) else { return nil }
        return AVAudioFormat(streamDescription: &asbd, channelLayout: discrete)
    }

    private static func sampleBuffer(from buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength), presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer
        else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        _ = CMSampleBufferSetDataReady(sampleBuffer)
        return sampleBuffer
    }
}

/// Hands one input buffer to `AVAudioConverter`'s input block, which the converter calls synchronously
/// inside `convert`. `@unchecked Sendable` because it never leaves that call.
private final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Carries a capture buffer onto the writer queue. `@unchecked Sendable` is sound because the caller
/// hands the buffer over and neither side mutates its contents afterwards.
private struct HandedOver<Value>: @unchecked Sendable {
    let value: Value
}
