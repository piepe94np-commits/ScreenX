import AVFoundation
import CoreMedia
import Testing
@testable import ScreenXCore

@Suite(.serialized)
struct RecordingFinalizerTests {
    private let width = 640
    private let height = 360

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenXFinalizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// All file names in `directory`, hidden ones included (to catch left-over temporary files).
    private func fileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func settings(audioTracks: Int, width: Int = 640, height: Int = 360, fps: Int = 30) -> VideoWriterSettings {
        VideoWriterSettings(size: CGSize(width: width, height: height), fps: fps, codec: .h264,
                            bitrate: 1_000_000, audioTracks: audioTracks)
    }

    /// A finished recording of `seconds` with one audio track per entry of `audio`.
    private func recordMov(in directory: URL, audio: [AudioTrackKind], seconds: Double) async throws -> URL {
        let url = directory.appendingPathComponent("ScreenX Aufnahme 2026-11-23 um 10.00.00.mov")
        let writer = try VideoFileWriter(url: url, settings: settings(audioTracks: audio.count))
        await SyntheticMedia.record(writer, from: 0, to: seconds, fps: 30, audio: audio,
                                    frame: SyntheticMedia.solidRecording(width: width, height: height))
        return try await writer.finish(stopAt: SyntheticMedia.hostTime(seconds))
    }

    private func expectPassthroughVideo(_ asset: AVURLAsset, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let video = try await asset.loadTracks(withMediaType: .video)
        try #require(video.count == 1, sourceLocation: sourceLocation)
        let description = try #require(try await video[0].load(.formatDescriptions).first, sourceLocation: sourceLocation)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264, sourceLocation: sourceLocation)
        let primaries = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        #expect(primaries == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, sourceLocation: sourceLocation)
        let size = try await video[0].load(.naturalSize)
        #expect(size == CGSize(width: width, height: height), sourceLocation: sourceLocation)
    }

    @Test func finalizeMixesTwoTracks() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mov = try await recordMov(in: directory, audio: [.system, .microphone], seconds: 3)
        let movAsset = AVURLAsset(url: mov)
        #expect(try await movAsset.loadTracks(withMediaType: .audio).count == 2)
        let movDuration = try await movAsset.load(.duration).seconds

        let mp4 = try await RecordingFinalizer.finalize(mov: mov)

        #expect(mp4 == RecordingFinalizer.finalURL(for: mov))
        #expect(!FileManager.default.fileExists(atPath: mov.path))
        let remaining = try fileNames(in: directory)
        #expect(remaining == [mp4.lastPathComponent])
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - movDuration) <= 0.1)
        #expect(abs(duration - 3) <= 0.1)
        try await expectPassthroughVideo(asset)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try #require(audio.count == 1)
        let description = try #require(try await audio[0].load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mChannelsPerFrame == 2)
        let audioDuration = try await audio[0].load(.timeRange).duration.seconds
        #expect(abs(audioDuration - 3) <= 0.1)
    }

    @Test func finalizeVideoOnly() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mov = try await recordMov(in: directory, audio: [], seconds: 2)

        let mp4 = try await RecordingFinalizer.finalize(mov: mov)

        #expect(!FileManager.default.fileExists(atPath: mov.path))
        let asset = AVURLAsset(url: mp4)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        try await expectPassthroughVideo(asset)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) <= 0.1)
    }

    /// A crash: the writer records 25 s in real time and never finishes. The file a crash leaves behind
    /// is the `.mov` exactly as it is on disk at that moment, so the test takes a copy of it while the
    /// writer is still running. Afterwards the writer finishes its own (live) file normally: a writer that
    /// is dropped or cancelled without `finish` left the encoder slowed down for the following writer
    /// tests on CI (dropped frames in four runs in a row; green without this test).
    @Test func unfinishedMovIsReadableAndFinalizes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mov = directory.appendingPathComponent("ScreenX Aufnahme 2026-11-23 um 11.00.00.mov")
        try await recordCrashedFile(to: mov, seconds: 25)
        let size = (try? FileManager.default.attributesOfItem(atPath: mov.path)[.size] as? NSNumber)?.int64Value
        print("unfinished mov: \(size ?? -1) bytes")

        let movDuration = try await AVURLAsset(url: mov).load(.duration).seconds
        print("unfinished mov duration: \(movDuration) s")
        #expect(movDuration >= 20)

        let mp4 = try await RecordingFinalizer.finalize(mov: mov)

        #expect(!FileManager.default.fileExists(atPath: mov.path))
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration).seconds
        print("finalized mp4 duration: \(duration) s")
        #expect(abs(duration - movDuration) <= 0.1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    /// Records in (about) real time, so fragments are written as in a real recording, copies the unfinished
    /// file to `crashed` (the state a crash leaves on disk), then finishes the live file only to release
    /// the encoder; the copy is never touched by the writer again.
    private func recordCrashedFile(to crashed: URL, seconds: Double) async throws {
        let live = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenXLive-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: live) }
        let writer = try VideoFileWriter(url: live, settings: settings(audioTracks: 1, width: 320, height: 180, fps: 10))
        await SyntheticMedia.record(writer, from: 0, to: seconds, fps: 10, audio: [.system],
                                    frameDelay: .milliseconds(100),
                                    frame: SyntheticMedia.solidRecording(width: 320, height: 180))
        try FileManager.default.copyItem(at: live, to: crashed)
        _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(seconds))
    }

    @Test func leftoversFound() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = [
            "ScreenX Aufnahme 2026-11-23 um 09.00.00.mov", "ScreenX Aufnahme 2026-11-23 um 09.00.00.mp4",
            "ScreenX Aufnahme 2026-11-23 um 10.00.00.mov", "Urlaub.mov",
            "ScreenX 2026-11-23 um 10.00.00.png",
        ]
        for name in names {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let single = directory.appendingPathComponent("ScreenX Aufnahme 2026-11-23 um 10.00.00.mov")

        #expect(RecordingFinalizer.leftovers(in: directory).map(\.lastPathComponent) == [single.lastPathComponent])
        #expect(RecordingFinalizer.leftovers(in: directory, excluding: [single]).isEmpty)
        #expect(RecordingFinalizer.finalURL(for: single).lastPathComponent == "ScreenX Aufnahme 2026-11-23 um 10.00.00.mp4")
    }

    @Test func failedFinalizeKeepsMov() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mov = directory.appendingPathComponent("ScreenX Aufnahme 2026-11-23 um 12.00.00.mov")
        try Data("kein Video".utf8).write(to: mov)

        await #expect(throws: RecordingFinalizerError.self) {
            _ = try await RecordingFinalizer.finalize(mov: mov)
        }

        #expect(FileManager.default.fileExists(atPath: mov.path))
        let remaining = try fileNames(in: directory)
        #expect(remaining == [mov.lastPathComponent])
    }
}
