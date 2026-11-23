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
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try #require(audio.count == 1)
        let audioSubtype = try await subtype(of: audio[0])
        #expect(audioSubtype == kAudioFormatMPEG4AAC)
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
    }

    @Test func bitrateRoughlyRespected() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let profile = RecordingProfile(id: "t", name: "T", resolution: .original, fps: 30, quality: .medium,
                                       codec: .h264)
        let size = CGSize(width: width, height: height)
        let writer = try VideoFileWriter(url: url, settings: VideoWriterSettings(profile: profile, targetSize: size))
        // One full-detail noise picture held for 10 s (worst case for screen content). Fresh full-entropy
        // noise in every frame cannot be compressed to this bit rate at all: H.264 hits its quantizer floor.
        let noise = SyntheticMedia.noiseFrame(width: width, height: height, seed: 1)
        await SyntheticMedia.record(writer, from: 0, to: 10, fps: 30) { _ in noise }
        _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(10))

        let estimateBytes = RecordingEstimate.megabytesPerMinute(profile: profile, source: size) * 1_000_000 / 6
        print("bitrateRoughlyRespected: \(writer.bytesWritten) bytes, estimate \(Int(estimateBytes)) bytes")
        #expect(writer.bytesWritten > 0)
        #expect(Double(writer.bytesWritten) <= 1.5 * estimateBytes)
    }

    @Test func finishWithoutFramesFails() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoFileWriter(url: url, settings: settings(audioTracks: 1))
        await #expect(throws: VideoWriterError.self) {
            _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(1))
        }
    }
}
