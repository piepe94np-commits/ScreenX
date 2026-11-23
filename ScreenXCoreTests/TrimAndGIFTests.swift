import AVFoundation
import CoreMedia
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
import VideoToolbox
@testable import ScreenXCore

/// Collects the values of a progress callback.
private final class ProgressLog: Sendable {
    let values = Mutex<[Double]>([])
    func add(_ value: Double) { values.withLock { $0.append(value) } }
    var all: [Double] { values.withLock { $0 } }
}

@Suite(.serialized)
struct TrimAndGIFTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenXTrimGIF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// All file names in `directory`, hidden ones included (to catch left-over temporary files).
    private func fileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// A finished `.mp4` made like a real recording: VideoFileWriter (keyframes every 2 s), then RecordingFinalizer.
    private func recording(
        in directory: URL, seconds: Double, width: Int = 640, height: Int = 360, fps: Int = 30,
        settings: VideoWriterSettings? = nil, frame: ((Double) -> CVPixelBuffer)? = nil
    ) async throws -> URL {
        let mov = directory.appendingPathComponent("ScreenX Aufnahme 2026-11-23 um 10.00.00.mov")
        let settings = settings ?? VideoWriterSettings(
            size: CGSize(width: width, height: height), fps: fps, codec: .h264, bitrate: 1_000_000, audioTracks: 0)
        let writer = try VideoFileWriter(url: mov, settings: settings)
        await SyntheticMedia.record(writer, from: 0, to: seconds, fps: fps,
                                    frame: frame ?? SyntheticMedia.solidRecording(width: width, height: height))
        _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(seconds))
        return try await RecordingFinalizer.finalize(mov: mov)
    }

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }

    // MARK: - Trim

    @Test func trimKeepsRangeApprox() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await recording(in: directory, seconds: 10)
        let destination = TrimExporter.trimmedURL(for: source)

        try await TrimExporter.export(source: source, range: range(2, 6), to: destination)

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        print("trimmed duration: \(duration) s")
        #expect(abs(duration - 4) <= 0.6)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try fileNames(in: directory) == [source.lastPathComponent, destination.lastPathComponent].sorted())

        // An existing file is never overwritten.
        await #expect(throws: TrimExporterError.destinationExists) {
            try await TrimExporter.export(source: source, range: range(0, 2), to: destination)
        }
        let unchanged = try await AVURLAsset(url: destination).load(.duration).seconds
        #expect(abs(unchanged - duration) < 0.001)
    }

    @Test func trimmedURLCounter() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Clip.mp4")
        try Data().write(to: source)

        let first = TrimExporter.trimmedURL(for: source)
        #expect(first.lastPathComponent == "Clip gekürzt.mp4")
        #expect(first.deletingLastPathComponent().path == directory.path)
        try Data().write(to: first)
        let second = TrimExporter.trimmedURL(for: source)
        #expect(second.lastPathComponent == "Clip gekürzt 2.mp4")
        try Data().write(to: second)
        #expect(TrimExporter.trimmedURL(for: source).lastPathComponent == "Clip gekürzt 3.mp4")

        let mov = directory.appendingPathComponent("Clip.mov")
        #expect(TrimExporter.trimmedURL(for: mov).lastPathComponent == "Clip gekürzt.mov")
    }

    @Test func trimRejectsUnknownFileTypeAndBrokenSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Kaputt.mp4")
        try Data("kein Video".utf8).write(to: source)

        await #expect(throws: TrimExporterError.unsupportedFileType) {
            try await TrimExporter.export(source: source, range: range(0, 1),
                                          to: directory.appendingPathComponent("Kaputt.gif"))
        }
        await #expect(throws: TrimExporterError.self) {
            try await TrimExporter.export(source: source, range: range(0, 1),
                                          to: TrimExporter.trimmedURL(for: source))
        }
        #expect(try fileNames(in: directory) == [source.lastPathComponent])
    }

    // MARK: - GIF

    @Test func gifFrameCountAndSize() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await recording(in: directory, seconds: 3)
        let gif = directory.appendingPathComponent("Clip.gif")
        let progress = ProgressLog()

        try await GIFEncoder.encode(source: source, range: nil, options: GIFOptions(width: 320, fps: 10, loops: true),
                                    to: gif) { progress.add($0) }

        let image = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetType(image) as String? == UTType.gif.identifier)
        #expect(CGImageSourceGetCount(image) == 30)
        let frame = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        #expect(frame[kCGImagePropertyPixelWidth] as? Int == 320)
        #expect(frame[kCGImagePropertyPixelHeight] as? Int == 180)
        let frameGIF = try #require(frame[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(frameGIF[kCGImagePropertyGIFUnclampedDelayTime] as? Double == 0.1)
        let container = try #require(CGImageSourceCopyProperties(image, nil) as? [CFString: Any])
        let containerGIF = try #require(container[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(containerGIF[kCGImagePropertyGIFLoopCount] as? Int == 0)

        let values = progress.all
        #expect(values.count == 30)
        #expect(values.last == 1.0)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        #expect(try fileNames(in: directory) == [gif.lastPathComponent, source.lastPathComponent].sorted())
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? NSNumber)
        print("gif solid 320x180x30: \(bytes.intValue) bytes, \(Double(bytes.intValue) / (320 * 180 * 30)) bytes/pixel-frame")
    }

    @Test func gifRangeAndPlaysOnce() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await recording(in: directory, seconds: 3)
        let gif = directory.appendingPathComponent("Clip.gif")

        try await GIFEncoder.encode(source: source, range: range(1, 2.5), options: GIFOptions(fps: 8, loops: false),
                                    to: gif) { _ in }

        let image = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        // 1.5 s × 8 fps = 12 frames, at the original size.
        #expect(CGImageSourceGetCount(image) == 12)
        let frame = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        #expect(frame[kCGImagePropertyPixelWidth] as? Int == 640)
        let container = CGImageSourceCopyProperties(image, nil) as? [CFString: Any]
        let containerGIF = container?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        print("plays once: read-back GIF properties \(String(describing: containerGIF))")
        print("plays once: NETSCAPE extension \(netscapeLoopBytes(try Data(contentsOf: gif)))")
    }

    /// Diagnostic for the report: what ImageIO writes for LoopCount 0, 1 and no LoopCount, and whether
    /// CGImageDestination keeps added images until it is finalized.
    @Test func imageIOLoopCountAndRetention() throws {
        let pixels = SyntheticMedia.solidFrame(width: 16, height: 16, colorIndex: 0)
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &cgImage)
        let image = try #require(cgImage)
        for loopCount in [0, 1, nil] as [Int?] {
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.gif.identifier as CFString, 2, nil))
            if let loopCount {
                CGImageDestinationSetProperties(destination, [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount],
                ] as CFDictionary)
            }
            let before = CFGetRetainCount(image)
            CGImageDestinationAddImage(destination, image, nil)
            let afterAdd = CFGetRetainCount(image)
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            let afterFinalize = CFGetRetainCount(image)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
            print("loopCount \(String(describing: loopCount)): NETSCAPE \(netscapeLoopBytes(data as Data)), "
                + "read back \(String(describing: properties?[kCGImagePropertyGIFDictionary])), "
                + "retain count before \(before) after add \(afterAdd) after finalize \(afterFinalize)")
        }
    }

    /// "none" or the loop count stored in the NETSCAPE2.0 application extension.
    private func netscapeLoopBytes(_ data: Data) -> String {
        let marker = Data("NETSCAPE2.0".utf8)
        guard let found = data.range(of: marker) else { return "none" }
        let bytes = [UInt8](data[found.upperBound..<min(data.count, found.upperBound + 4)])
        guard bytes.count == 4 else { return "truncated" }
        return "sub-block \(bytes[0]) id \(bytes[1]) loops \(Int(bytes[2]) | Int(bytes[3]) << 8)"
    }

    @Test func frameDelaysSumExact() {
        let delays = GIFEncoder.frameDelays(fps: 15, count: 45)
        #expect(delays.count == 45)
        #expect(delays.allSatisfy { [6, 7].contains(Int(($0 * 100).rounded())) })
        #expect(abs(delays.reduce(0, +) - 3.0) < 1e-9)
        // The running sum stays within half a hundredth of i / fps.
        for fps in [15, 10, 8, 24, 60] {
            var sum = 0.0
            for (i, delay) in GIFEncoder.frameDelays(fps: fps, count: 200).enumerated() {
                sum += delay
                #expect(abs(sum - Double(i + 1) / Double(fps)) <= 0.005 + 1e-9)
            }
        }
        #expect(GIFEncoder.frameDelays(fps: 10, count: 3) == [0.1, 0.1, 0.1])
        #expect(GIFEncoder.frameDelays(fps: 10, count: 0).isEmpty)
    }

    @Test func gifCancelDeletesFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await recording(in: directory, seconds: 10)
        let gif = directory.appendingPathComponent("Clip.gif")

        let task = Task {
            try await GIFEncoder.encode(source: source, range: nil, options: GIFOptions(fps: 15, loops: true),
                                        to: gif) { value in
                // The callback runs inside the encoding task: cancel it after a few frames.
                if value > 0.05 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await task.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: gif.path))
        #expect(try fileNames(in: directory) == [source.lastPathComponent])
    }

    @Test func gifFailsCleanlyOnBrokenSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Kaputt.mp4")
        try Data("kein Video".utf8).write(to: source)

        await #expect(throws: GIFEncoderError.self) {
            try await GIFEncoder.encode(source: source, range: nil, options: GIFOptions(), to:
                directory.appendingPathComponent("Kaputt.gif")) { _ in }
        }
        #expect(try fileNames(in: directory) == [source.lastPathComponent])
    }

    /// Realistic content: scrolling dense text (SyntheticMedia.ScrollingText, 4 px per frame), recorded
    /// with the settings of the built-in GIF profile (480p, 10 fps, H.264 small), then a GIF at the video size.
    @Test func gifEstimateWithinFactor2() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try #require(RecordingProfile.builtins.first { $0.id == "gif" })
        let size = RecordingEstimate.targetSize(source: CGSize(width: 1708, height: 960), resolution: profile.resolution)
        let width = Int(size.width), height = Int(size.height)
        let seconds = 3.0
        let text = SyntheticMedia.ScrollingText(width: width, height: height,
                                                maxOffset: Int(seconds) * profile.fps * 4 + 8)
        let source = try await recording(
            in: directory, seconds: seconds, fps: profile.fps,
            settings: VideoWriterSettings(profile: profile, targetSize: size),
            frame: { t in text.frame(offset: Int((t * Double(profile.fps)).rounded()) * 4) })
        let gif = directory.appendingPathComponent("Text.gif")

        try await GIFEncoder.encode(source: source, range: nil, options: GIFOptions(fps: profile.fps, loops: true),
                                    to: gif) { _ in }

        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? NSNumber)
        let actual = Double(bytes.intValue) / 1_000_000
        let estimate = RecordingEstimate.gifMegabytes(size: size, fps: profile.fps, seconds: seconds)
        let perPixelFrame = Double(bytes.intValue) / (size.width * size.height * Double(profile.fps) * seconds)
        print("gif text \(width)x\(height): \(bytes.intValue) bytes, \(perPixelFrame) bytes/pixel-frame, "
            + "estimate \(estimate) MB, actual \(actual) MB, ratio \(actual / estimate)")
        #expect(actual / estimate <= 2)
        #expect(actual / estimate >= 0.5)
    }
}
