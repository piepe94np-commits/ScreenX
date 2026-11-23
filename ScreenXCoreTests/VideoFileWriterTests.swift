import AVFoundation
import CoreMedia
import Testing
@testable import ScreenXCore

@Suite(.serialized)
struct VideoFileWriterTests {
    private let width = 640
    private let height = 360

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScreenXWriter-\(UUID().uuidString).mov")
    }

    private func settings(codec: VideoCodec = .h264, audioTracks: Int) -> VideoWriterSettings {
        VideoWriterSettings(size: CGSize(width: width, height: height), fps: 30, codec: codec,
                            bitrate: 1_000_000, audioTracks: audioTracks)
    }

    private func subtype(of track: AVAssetTrack) async throws -> FourCharCode? {
        try await track.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
    }

    private func expectNoDrops(_ writer: VideoFileWriter, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(writer.droppedVideoFrames == 0, sourceLocation: sourceLocation)
        #expect(writer.droppedAudioBuffers == 0, sourceLocation: sourceLocation)
    }

    /// The track is AAC at 48 kHz stereo and lasts about `duration` seconds.
    private func expectNormalizedAAC(_ track: AVAssetTrack, duration: Double,
                                     sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC,
                sourceLocation: sourceLocation)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
        #expect(asbd.mSampleRate == 48_000, sourceLocation: sourceLocation)
        #expect(asbd.mChannelsPerFrame == 2, sourceLocation: sourceLocation)
        let trackDuration = try await track.load(.timeRange).duration.seconds
        #expect(abs(trackDuration - duration) <= 0.1, sourceLocation: sourceLocation)
    }

    private func checkPlayableMov(codec: VideoCodec, expectedSubtype: FourCharCode) async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: settings(codec: codec, audioTracks: 1))
        await SyntheticMedia.record(writer, from: 0, to: 3, fps: 30, audio: [.system],
                                    frame: SyntheticMedia.solidRecording(width: width, height: height))
        let out = try await writer.finish(stopAt: SyntheticMedia.hostTime(3))

        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) <= 0.1)
        let video = try await asset.loadTracks(withMediaType: .video)
        try #require(video.count == 1)
        let size = try await video[0].load(.naturalSize)
        #expect(size == CGSize(width: width, height: height))
        let videoSubtype = try await subtype(of: video[0])
        #expect(videoSubtype == expectedSubtype)
        let videoDescription = try #require(try await video[0].load(.formatDescriptions).first)
        let primaries = CMFormatDescriptionGetExtension(
            videoDescription, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        #expect(primaries == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try #require(audio.count == 1)
        try await expectNormalizedAAC(audio[0], duration: 3)
        expectNoDrops(writer)
    }

    /// Index of the palette color closest to the center pixel of the frame at `seconds`.
    private func paletteIndex(of asset: AVURLAsset, at seconds: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let center = CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                            width: CGFloat(image.width), height: CGFloat(image.height))
        context.draw(image, in: center)
        let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let distances = SyntheticMedia.palette.map { c in
            [Int(c.r) - Int(pixel[0]), Int(c.g) - Int(pixel[1]), Int(c.b) - Int(pixel[2])]
                .reduce(0) { $0 + $1 * $1 }
        }
        return distances.indices.min { distances[$0] < distances[$1] }!
    }

    @Test func settingsFromProfile() {
        let meeting = RecordingProfile.builtins[0]
        let size = CGSize(width: 1920, height: 1080)
        let s = VideoWriterSettings(profile: meeting, targetSize: size)
        #expect(s.size == size)
        #expect(s.fps == 24)
        #expect(s.codec == .hevc)
        #expect(s.bitrate == RecordingEstimate.videoBitrate(size: size, fps: 24, quality: .medium, codec: .hevc))
        #expect(s.audioTracks == 2)
        #expect(VideoWriterSettings(profile: RecordingProfile.builtins[3], targetSize: size).audioTracks == 0)
    }

    @Test func writesPlayableMovH264() async throws {
        try await checkPlayableMov(codec: .h264, expectedSubtype: kCMVideoCodecType_H264)
    }

    @Test(.enabled(if: SyntheticMedia.canEncodeHEVC, "kein HEVC-Encoder verfügbar"))
    func writesHEVC() async throws {
        try await checkPlayableMov(codec: .hevc, expectedSubtype: kCMVideoCodecType_HEVC)
    }

    @Test func writerPauseResume() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: settings(audioTracks: 1))
        let frames = SyntheticMedia.solidRecording(width: width, height: height)
        await SyntheticMedia.record(writer, from: 0, to: 2, fps: 30, audio: [.system], frame: frames)
        writer.pause(at: SyntheticMedia.hostTime(2))
        writer.resume(at: SyntheticMedia.hostTime(7))
        await SyntheticMedia.record(writer, from: 7, to: 9, fps: 30, audio: [.system], frame: frames)
        let out = try await writer.finish(stopAt: SyntheticMedia.hostTime(9))

        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 4) <= 0.1)
        let before = try await paletteIndex(of: asset, at: 1.5)
        #expect(before == SyntheticMedia.colorIndex(at: 1.5))
        let after = try await paletteIndex(of: asset, at: 2.5)
        #expect(after == SyntheticMedia.colorIndex(at: 7.5))
        expectNoDrops(writer)
    }

    @Test func audioStraddlingPauseStartIsKept() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: settings(audioTracks: 1))
        let frames = SyntheticMedia.solidRecording(width: width, height: height)
        // The last buffer before the pause runs about 5 ms past the pause start.
        await SyntheticMedia.record(writer, from: 0, to: 2, fps: 30, audio: [.system], audioPastEnd: true,
                                    frame: frames)
        writer.pause(at: SyntheticMedia.hostTime(2))
        writer.resume(at: SyntheticMedia.hostTime(7))
        await SyntheticMedia.record(writer, from: 7, to: 9, fps: 30, audio: [.system], frame: frames)
        let out = try await writer.finish(stopAt: SyntheticMedia.hostTime(9))

        let audio = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        try #require(audio.count == 1)
        try await expectNormalizedAAC(audio[0], duration: 4)
        expectNoDrops(writer)
        #expect(writer.failure == nil)
    }

    static let realAudioFormats: [String: SyntheticMedia.SineFormat] = [
        "mono48k": .mono48k, "mono44k": .mono44k, "planarStereo48k": .planarStereo48k, "quad48k": .quad48k,
    ]

    @Test(arguments: ["mono48k", "mono44k", "planarStereo48k", "quad48k"])
    func realAudioFormatsAreNormalized(_ name: String) async throws {
        let format = try #require(Self.realAudioFormats[name])
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: settings(audioTracks: 2))
        await SyntheticMedia.record(writer, from: 0, to: 2, fps: 30, audio: [.microphone], audioFormat: format,
                                    frame: SyntheticMedia.solidRecording(width: width, height: height))
        let out = try await writer.finish(stopAt: SyntheticMedia.hostTime(2))

        let audio = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        let withData = try await audio.asyncFilter { try await $0.load(.timeRange).duration.seconds > 0 }
        try #require(withData.count == 1)
        try await expectNormalizedAAC(withData[0], duration: 2)
        expectNoDrops(writer)
        #expect(writer.failure == nil)
    }

    @Test func audioFormatChangeMidStream() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: settings(audioTracks: 1))
        let frames = SyntheticMedia.solidRecording(width: width, height: height)
        await SyntheticMedia.record(writer, from: 0, to: 1, fps: 30, audio: [.microphone],
                                    audioFormat: .stereo48k, audioPastEnd: true, frame: frames)
        await SyntheticMedia.record(writer, from: 1, to: 2, fps: 30, audio: [.microphone],
                                    audioFormat: .mono44k, frame: frames)
        let out = try await writer.finish(stopAt: SyntheticMedia.hostTime(2))

        let audio = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        try #require(audio.count == 1)
        try await expectNormalizedAAC(audio[0], duration: 2)
        expectNoDrops(writer)
        #expect(writer.failure == nil)
    }

    @Test func lastFrameHeldUntilStop() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: settings(audioTracks: 0))
        await SyntheticMedia.record(writer, from: 0, to: 1, fps: 30,
                                    frame: SyntheticMedia.solidRecording(width: width, height: height))
        let out = try await writer.finish(stopAt: SyntheticMedia.hostTime(4))

        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 4) <= 0.1)
        let video = try await asset.loadTracks(withMediaType: .video)
        try #require(video.count == 1)
        let trackDuration = try await video[0].load(.timeRange).duration.seconds
        #expect(abs(trackDuration - 4) <= 0.1)
        expectNoDrops(writer)
    }

    @Test func twoAudioTracks() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: settings(audioTracks: 2))
        await SyntheticMedia.record(writer, from: 0, to: 2, fps: 30, audio: [.system, .microphone],
                                    frame: SyntheticMedia.solidRecording(width: width, height: height))
        let out = try await writer.finish(stopAt: SyntheticMedia.hostTime(2))

        let audio = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        #expect(audio.count == 2)
        for track in audio {
            let trackDuration = try await track.load(.timeRange).duration.seconds
            #expect(trackDuration > 1.5)
        }
        expectNoDrops(writer)
    }

    @Test func bitrateRoughlyRespected() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let profile = RecordingProfile(id: "t", name: "T", resolution: .original, fps: 30, quality: .medium,
                                       codec: .h264)
        let size = CGSize(width: width, height: height)
        let writer = try VideoFileWriter(url: url, settings: VideoWriterSettings(profile: profile, targetSize: size))
        // Gray noise of 4×4 cells scrolling 4 px per frame: a detailed, constantly moving screen. Finer noise
        // cannot reach this bit rate at all: with a keyframe every 2 s, its keyframes alone exceed the budget.
        await SyntheticMedia.record(writer, from: 0, to: 10, fps: 30) { t in
            SyntheticMedia.blockNoiseFrame(width: width, height: height, block: 4, offset: Int((t * 120).rounded()))
        }
        _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(10))

        let estimateBytes = RecordingEstimate.megabytesPerMinute(profile: profile, source: size) * 1_000_000 / 6
        print("bitrateRoughlyRespected: \(writer.bytesWritten) bytes, estimate \(Int(estimateBytes)) bytes")
        #expect(writer.usesDataRateLimit)
        #expect(writer.bytesWritten > 0)
        #expect(Double(writer.bytesWritten) <= 1.5 * estimateBytes)
    }

    private func estimatedBytes(_ profile: RecordingProfile, _ size: CGSize, seconds: Double) -> Double {
        RecordingEstimate.megabytesPerMinute(profile: profile, source: size) * 1_000_000 / 60 * seconds
    }

    /// Fresh full-resolution noise in every frame (pathological); returns the size relative to the estimate.
    private func noiseRatio(codec: VideoCodec) async throws -> (ratio: Double, limited: Bool) {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let profile = RecordingProfile(id: "t", name: "T", resolution: .original, fps: 30, quality: .medium,
                                       codec: codec)
        let size = CGSize(width: width, height: height)
        let writer = try VideoFileWriter(url: url, settings: VideoWriterSettings(profile: profile, targetSize: size))
        var seed: UInt64 = 1
        await SyntheticMedia.record(writer, from: 0, to: 10, fps: 30) { _ in
            seed += 1
            return SyntheticMedia.noiseFrame(width: width, height: height, seed: seed)
        }
        _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(10))
        let ratio = Double(writer.bytesWritten) / estimatedBytes(profile, size, seconds: 10)
        print("hevcNoiseStaysBounded \(codec): \(writer.bytesWritten) bytes, ratio \(ratio)")
        return (ratio, writer.usesDataRateLimit)
    }

    @Test(.enabled(if: SyntheticMedia.canEncodeHEVC, "kein HEVC-Encoder verfügbar"))
    func hevcNoiseStaysBounded() async throws {
        let result = try await noiseRatio(codec: .hevc)
        #expect(result.limited)
        #expect(result.ratio <= 3.0)
    }

    /// 10 s of dense small text scrolling 6 px per frame at 1280×720/30/medium.
    private func checkScrollingText(codec: VideoCodec) async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let profile = RecordingProfile(id: "t", name: "T", resolution: .original, fps: 30, quality: .medium,
                                       codec: codec)
        let size = CGSize(width: 1280, height: 720)
        let writer = try VideoFileWriter(url: url, settings: VideoWriterSettings(profile: profile, targetSize: size))
        let text = SyntheticMedia.ScrollingText(width: 1280, height: 720, maxOffset: 6 * 300)
        await SyntheticMedia.record(writer, from: 0, to: 10, fps: 30) { t in
            text.frame(offset: 6 * Int((t * 30).rounded()))
        }
        _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(10))
        let ratio = Double(writer.bytesWritten) / estimatedBytes(profile, size, seconds: 10)
        print("detailedScrollingTextStaysNearEstimate \(codec): \(writer.bytesWritten) bytes, ratio \(ratio), "
              + "dropped \(writer.droppedVideoFrames)")
        #expect(writer.usesDataRateLimit)
        #expect(ratio <= 1.5)
    }

    @Test func detailedScrollingTextStaysNearEstimate() async throws {
        try await checkScrollingText(codec: .h264)
    }

    @Test(.enabled(if: SyntheticMedia.canEncodeHEVC, "kein HEVC-Encoder verfügbar"))
    func detailedScrollingTextStaysNearEstimateHEVC() async throws {
        try await checkScrollingText(codec: .hevc)
    }

    @Test(.timeLimit(.minutes(1)))
    func failureIsRecordedAndReported() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: settings(audioTracks: 0))
        let frames = SyntheticMedia.solidRecording(width: width, height: height)
        await SyntheticMedia.record(writer, from: 0, to: 0.5, fps: 30, frame: frames)
        #expect(writer.failure == nil)
        // The writer leaves `.writing` behind our back; the next append detects it.
        writer.simulateWriterFailureForTesting()
        let reported = await withCheckedContinuation { (continuation: CheckedContinuation<VideoWriterError, Never>) in
            writer.onFailure = { continuation.resume(returning: $0) }
            writer.appendVideo(frames(0.6), hostTime: SyntheticMedia.hostTime(0.6))
        }
        #expect(writer.failure == reported)
        await #expect(throws: VideoWriterError.self) {
            _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(1))
        }
    }

    @Test func finishWithoutFramesFails() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: settings(audioTracks: 1))
        await #expect(throws: VideoWriterError.self) {
            _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(1))
        }
        // Finish errors are thrown only; `failure` reports failures during recording.
        #expect(writer.failure == nil)
    }

    /// Records `seconds` of video (10 fps) and microphone audio whose host clock drifts by `ppm`.
    private func checkDrift(ppm: Double, seconds: Double, endTolerance: Double) async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: VideoWriterSettings(
            size: CGSize(width: width, height: height), fps: 10, codec: .h264, bitrate: 500_000, audioTracks: 1))
        await SyntheticMedia.record(writer, from: 0, to: seconds, fps: 10, audio: [.microphone],
                                    audioPastEnd: true, audioDriftPPM: ppm, frameDelay: .milliseconds(10),
                                    frame: SyntheticMedia.solidRecording(width: width, height: height))
        let out = try await writer.finish(stopAt: SyntheticMedia.hostTime(seconds))
        #expect(writer.failure == nil)
        expectNoDrops(writer)

        let asset = AVURLAsset(url: out)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try #require(audio.count == 1)
        let end = try await audio[0].load(.timeRange).end.seconds
        print("drift \(ppm) ppm: audio ends at \(end) s, stop \(seconds) s")
        #expect(abs(end - seconds) <= endTolerance)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        // Passthrough AAC comes in chunks of packets; marker buffers without samples carry no timing.
        var previousEnd: CMTime?
        var count = 0
        var violations: [String] = []
        let tolerance = CMTime(value: 1, timescale: 48_000)
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard CMSampleBufferGetNumSamples(sample) > 0, pts.isValid else { continue }
            if let previousEnd, CMTimeCompare(pts, CMTimeSubtract(previousEnd, tolerance)) < 0 {
                violations.append("#\(count): starts \(pts.seconds) before previous end \(previousEnd.seconds)")
            }
            previousEnd = CMTimeAdd(pts, CMSampleBufferGetDuration(sample))
            count += 1
        }
        #expect(count > 0)
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test(arguments: [300.0, -300.0])
    func longDriftingAudioStaysInSyncAndMonotonic(_ ppm: Double) async throws {
        try await checkDrift(ppm: ppm, seconds: 60, endTolerance: 0.02)
    }

    /// Strong drift forces resyncs (forward gaps, backward trims) within 30 s.
    @Test(arguments: [1000.0, -1000.0])
    func strongDriftResyncsWithoutOverlap(_ ppm: Double) async throws {
        try await checkDrift(ppm: ppm, seconds: 30, endTolerance: 0.03)
    }
}

private extension Array {
    func asyncFilter(_ isIncluded: (Element) async throws -> Bool) async rethrows -> [Element] {
        var result: [Element] = []
        for element in self where try await isIncluded(element) { result.append(element) }
        return result
    }
}
