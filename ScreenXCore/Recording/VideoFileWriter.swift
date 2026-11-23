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
        case .buffer(let converted):
            if !input.append(converted) { recordFailure(writerError()) }
        case .empty:
            break
        case .covered, .failed:
            dropAudio(track: index)
        }
    }

    /// Counts and logs an audio drop and lets the track's normalizer resync on its next buffer.
    private func dropAudio(track index: Int) {
        statistics.withLock { $0.droppedAudioBuffers += 1 }
        normalizers[index].noteDrop()
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

/// Converts one track's incoming audio (any linear PCM format, possibly changing mid-stream, e.g. after
/// a microphone switch) to interleaved float32 48 kHz stereo. Confined to the writer queue.
///
/// Timing: output runs continuously by sample count, so the audio has no steps while the device clock
/// and the host clock agree. When they drift apart by more than `resyncThreshold` (20–200 ppm of device
/// drift reaches that after minutes), after a drop, or across a pause gap, the output restarts at the
/// buffer's host-derived time. A forward resync leaves a gap of at most the threshold; a backward one
/// trims the converted buffer's leading frames so no output starts before the previous output end
/// (a buffer that is fully covered is dropped). The sync error therefore stays below 20 ms.
private final class AudioNormalizer {
    enum Result {
        case buffer(CMSampleBuffer)
        /// The converter produced no frames yet (not a drop).
        case empty
        /// Fully covered by earlier output; dropped.
        case covered
        case failed
    }

    private let outputFormat = VideoWriterSettings.normalizedAudioFormat()
    private var converter: AVAudioConverter?
    private var inputDescription: CMFormatDescription?
    private var inputFormat: AVAudioFormat?
    /// Output time at which the next converted frames continue.
    private var nextTime: CMTime?
    /// End of the last emitted output; nothing may start before it.
    private var outputEnd: CMTime?
    private var needsResync = false
    private static let resyncThreshold = CMTime(value: 20, timescale: 1000)

    /// A buffer of this track was dropped: restart timing at the next buffer.
    func noteDrop() {
        needsResync = true
    }

    /// Converts `sampleBuffer`, whose start maps to output time `time`.
    func convert(_ sampleBuffer: CMSampleBuffer, at time: CMTime) -> Result {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return .failed }
        if inputDescription.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: description) }) ?? true {
            guard let format = Self.audioFormat(of: description),
                  let converter = AVAudioConverter(from: format, to: outputFormat) else {
                return .failed
            }
            converter.primeMethod = .none
            converter.downmix = format.channelCount > outputFormat.channelCount
            self.converter = converter
            // `nextTime` is kept, so output stays continuous across a format change.
            inputFormat = format
            inputDescription = description
        }
        guard let converter, let inputFormat else { return .failed }
        if needsResync || nextTime.map({
            CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(time, $0)), Self.resyncThreshold) > 0
        }) ?? true {
            converter.reset()
            nextTime = time
            needsResync = false
        }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else {
            return .failed
        }
        guard Self.copyPCM(from: sampleBuffer, into: input) else { return .failed }
        input.frameLength = frames

        let capacity = AVAudioFrameCount(
            (Double(frames) * outputFormat.sampleRate / inputFormat.sampleRate).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return .failed
        }
        let pending = PendingInput(buffer: input)
        var error: NSError?
        // Mid-stream the block answers `.noDataNow`, never `.endOfStream`: that would end the converter's
        // stream. Flushing the resampler's tail at the very end is not needed.
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let buffer = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return .failed }
        guard output.frameLength > 0, var start = nextTime else { return .empty }

        let rate = CMTimeScale(outputFormat.sampleRate)
        let produced = CMTime(value: CMTimeValue(output.frameLength), timescale: rate)
        var skip: AVAudioFrameCount = 0
        if let outputEnd, CMTimeCompare(start, outputEnd) < 0 {
            let overlap = CMTimeSubtract(outputEnd, start).seconds * outputFormat.sampleRate
            guard overlap < Double(output.frameLength) else {
                nextTime = CMTimeAdd(start, produced)
                return .covered
            }
            skip = AVAudioFrameCount(overlap.rounded(.up))
            start = outputEnd
        }
        let end = CMTimeAdd(start, CMTime(value: CMTimeValue(output.frameLength - skip), timescale: rate))
        guard let result = Self.sampleBuffer(from: output, skipping: skip, at: start) else { return .failed }
        nextTime = end
        outputEnd = end
        return .buffer(result)
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

    /// Copies the sample buffer's PCM data (interleaved or one plane per channel) into `buffer`.
    private static func copyPCM(from sampleBuffer: CMSampleBuffer, into buffer: AVAudioPCMBuffer) -> Bool {
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
            listSize > 0
        else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer) == noErr
        else { return false }
        let source = UnsafeMutableAudioBufferListPointer(listPointer)
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard source.count == destination.count else { return false }
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { return false }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return withExtendedLifetime(blockBuffer) { true }
    }

    /// Wraps interleaved PCM, without its first `skip` frames, in a ready `CMSampleBuffer` starting at `time`.
    private static func sampleBuffer(from buffer: AVAudioPCMBuffer, skipping skip: AVAudioFrameCount,
                                     at time: CMTime) -> CMSampleBuffer? {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard list.count == 1, let base = list[0].mData, skip < buffer.frameLength else { return nil }
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let data = base + Int(skip) * bytesPerFrame
        let frameCount = buffer.frameLength - skip
        let byteCount = Int(frameCount) * bytesPerFrame
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            CMBlockBufferReplaceDataBytes(
                with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) == noErr
        else { return nil }
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(frameCount), presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr
        else { return nil }
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
