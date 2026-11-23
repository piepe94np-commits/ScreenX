import AVFoundation
import CoreMedia
import CoreVideo

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
///
/// `@unchecked Sendable`: every access to the writer, its inputs and the mutable state below happens on
/// the private serial `queue`; public methods only enqueue work there.
public final class VideoFileWriter: @unchecked Sendable {
    public let url: URL
    public let settings: VideoWriterSettings

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
    private var dropped = 0
    private var finishing = false

    /// Tolerance for rounding between host-clock timescales when checking audio buffers for overlap.
    private static let audioOverlapTolerance = CMTime(value: 1, timescale: 1000)

    public init(url: URL, settings: VideoWriterSettings) throws {
        self.url = url
        self.settings = settings

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw VideoWriterError.cannotCreate
        }
        writer.movieFragmentInterval = CMTime(
            seconds: VideoWriterSettings.fragmentIntervalSeconds, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let videoSettings = settings.videoOutputSettings
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw VideoWriterError.cannotCreate
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw VideoWriterError.cannotCreate }
        writer.add(videoInput)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(settings.size.width),
                kCVPixelBufferHeightKey as String: Int(settings.size.height),
            ])

        let audioSettings = settings.audioOutputSettings
        var audioInputs: [AVAssetWriterInput] = []
        for _ in 0..<settings.audioTracks {
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw VideoWriterError.cannotCreate
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw VideoWriterError.cannotCreate }
            writer.add(input)
            audioInputs.append(input)
        }

        guard writer.startWriting() else { throw VideoWriterError.cannotCreate }
        self.writer = writer
        self.videoInput = videoInput
        self.audioInputs = audioInputs
        self.audioEnds = Array(repeating: nil, count: audioInputs.count)
    }

    /// Current size of the output file in bytes.
    public var bytesWritten: Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return size?.int64Value ?? 0
    }

    /// Number of buffers dropped because an input was not ready for more data.
    public var droppedBufferCount: Int {
        queue.sync { dropped }
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime) {
        let box = HandedOver(value: pixelBuffer)
        queue.async { self.writeVideo(box.value, hostTime: hostTime) }
    }

    /// Appends an audio buffer to the track of `track`. With a single audio track, every source
    /// goes to that track (only one source is active then).
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

    private func writeVideo(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime) {
        guard !finishing, writer.status == .writing, let time = timeline.video(at: hostTime) else { return }
        if let lastVideoTime, CMTimeCompare(time, lastVideoTime) <= 0 { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else {
            dropped += 1
            return
        }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastVideoTime = time
        }
    }

    private func writeAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrackKind) {
        guard !finishing, writer.status == .writing, !audioInputs.isEmpty else { return }
        let index = (track == .microphone && audioInputs.count > 1) ? 1 : 0
        let hostTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard hostTime.isValid else { return }
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if !duration.isValid { duration = .zero }
        guard let time = timeline.audio(at: hostTime, duration: duration), sessionStarted else { return }
        // A buffer that straddled a pause start would overlap the first one after resuming.
        if let end = audioEnds[index],
           CMTimeCompare(time, CMTimeSubtract(end, Self.audioOverlapTolerance)) < 0 { return }
        guard let retimed = Self.retime(sampleBuffer, by: CMTimeSubtract(time, hostTime)) else { return }
        let input = audioInputs[index]
        guard input.isReadyForMoreMediaData else {
            dropped += 1
            return
        }
        if input.append(retimed) {
            audioEnds[index] = CMTimeAdd(time, duration)
        }
    }

    private func finishOnQueue(stopAt hostTime: CMTime, continuation: CheckedContinuation<URL, Error>) {
        guard !finishing, writer.status == .writing else {
            continuation.resume(throwing: failure())
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
                    continuation.resume(throwing: self.failure())
                }
            }
        }
    }

    private func failure() -> VideoWriterError {
        .writerFailed(writer.error?.localizedDescription ?? String(localized: "Unbekannter Fehler"))
    }

    /// Copies `sampleBuffer` with every timestamp shifted by `offset`.
    private static func retime(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr
        else { return nil }
        for i in timings.indices {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, offset)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeAdd(timings[i].decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count,
            sampleTimingArray: &timings, sampleBufferOut: &copy) == noErr
        else { return nil }
        return copy
    }
}

/// Carries a capture buffer onto the writer queue. `@unchecked Sendable` is sound because the caller
/// hands the buffer over and neither side mutates its contents afterwards.
private struct HandedOver<Value>: @unchecked Sendable {
    let value: Value
}
