import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

public struct GIFOptions: Sendable, Equatable {
    /// Width of the GIF in pixels (the height follows the aspect ratio); `nil` keeps the video size.
    /// The video is never scaled up.
    public var width: Int?
    public var fps: Int
    /// Endless loop; otherwise the GIF plays once.
    public var loops: Bool

    public init(width: Int? = nil, fps: Int = 10, loops: Bool = true) {
        self.width = width
        self.fps = fps
        self.loops = loops
    }
}

public enum GIFEncoderError: Error, Equatable, Sendable {
    /// The destination already exists; it is never overwritten.
    case destinationExists
    /// The source could not be opened.
    case unreadable(String)
    /// The source has no video track.
    case noVideo
    /// A frame of the video could not be read.
    case frameFailed(String)
    /// The GIF could not be written.
    case writeFailed(String)
}

extension GIFEncoderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .destinationExists:
            String(localized: "Es gibt bereits eine Datei mit diesem Namen.")
        case .unreadable(let reason):
            String(localized: "Das Video konnte nicht gelesen werden: \(reason)")
        case .noVideo:
            String(localized: "Die Datei enthält kein Video.")
        case .frameFailed(let reason):
            String(localized: "Ein Bild des Videos konnte nicht gelesen werden: \(reason)")
        case .writeFailed(let reason):
            String(localized: "Das GIF konnte nicht gespeichert werden: \(reason)")
        }
    }
}

/// Turns a video (or a part of it) into an animated GIF.
public enum GIFEncoder {
    /// Frames are requested from the image generator in batches of this size, so only a few decoded frames
    /// are waiting at any time while the generator can still decode them in sequence.
    static let batchSize = 10

    /// Samples `range` (or the whole video) at `options.fps`, starting at the range start, with
    /// floor(duration × fps) frames (at least 1). Each frame is fetched and added on its own.
    ///
    /// Memory: `CGImageDestination` keeps every added image until it is finalized, so each decoded frame is
    /// replaced by a lossless PNG-backed image first (`compactFrame`); only the compressed frames stay in memory.
    /// The GIF is encoded in memory, then written under a hidden temporary name next to `destination` and
    /// moved into place, so nothing touches the disk before the encoding is complete.
    /// `progress` gets 0…1 after each frame and 1.0 once the file is in place. On cancellation (checked per
    /// frame) or any error the temporary file is removed and the error (`CancellationError` on cancel) is thrown.
    public static func encode(
        source: URL, range: CMTimeRange?, options: GIFOptions, to destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GIFEncoderError.destinationExists
        }
        let asset = AVURLAsset(url: source)
        let duration: CMTime
        let displaySize: CGSize
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw GIFEncoderError.noVideo
            }
            duration = try await asset.load(.duration)
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = naturalSize.applying(transform)
            displaySize = CGSize(width: abs(shown.width), height: abs(shown.height))
        } catch let error as GIFEncoderError {
            throw error
        } catch {
            throw GIFEncoderError.unreadable(error.localizedDescription)
        }

        let fps = max(1, options.fps)
        let whole = CMTimeRange(start: .zero, duration: duration)
        let span = range.map { $0.intersection(whole) } ?? whole
        let start = span.start.isValid ? span.start : .zero
        let seconds = span.duration.isValid ? max(0, span.duration.seconds) : 0
        // The small epsilon keeps 3.0 s × 10 fps at 30 frames despite rounding in CMTime seconds.
        let count = max(1, Int((seconds * Double(fps) + 1e-6).rounded(.down)))
        let times = (0..<count).map { CMTimeAdd(start, CMTime(value: Int64($0), timescale: CMTimeScale(fps))) }
        let delays = frameDelays(fps: fps, count: count)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let width = options.width, width > 0, displaySize.width > 0, CGFloat(width) < displaySize.width {
            // The height bound is a little larger than the aspect ratio needs, so the width decides.
            let height = (CGFloat(width) * displaySize.height / displaySize.width).rounded(.up) + 2
            generator.maximumSize = CGSize(width: CGFloat(width), height: height)
        }

        let temp = TrimExporter.temporaryURL(for: destination, purpose: "encoding")
        try? FileManager.default.removeItem(at: temp)
        do {
            // A URL destination writes its own hidden helper file, which stays behind when the encoding is
            // cancelled before `CGImageDestinationFinalize`; a data destination never touches the disk.
            let data = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.gif.identifier as CFString, count, nil)
            else {
                throw GIFEncoderError.writeFailed(String(localized: "Unbekannter Fehler"))
            }
            CGImageDestinationSetProperties(output, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: options.loops ? 0 : 1],
            ] as CFDictionary)

            var index = 0
            defer { generator.cancelAllCGImageGeneration() }
            for batchStart in stride(from: 0, to: count, by: batchSize) {
                try Task.checkCancellation()
                let batch = Array(times[batchStart..<min(count, batchStart + batchSize)])
                for await result in generator.images(for: batch) {
                    try Task.checkCancellation()
                    let decoded: CGImage
                    do {
                        decoded = try result.image
                    } catch {
                        throw GIFEncoderError.frameFailed(error.localizedDescription)
                    }
                    let image = try compactFrame(decoded)
                    let delay = delays[index]
                    CGImageDestinationAddImage(output, image, [
                        kCGImagePropertyGIFDictionary: [
                            kCGImagePropertyGIFUnclampedDelayTime: delay,
                            kCGImagePropertyGIFDelayTime: delay,
                        ],
                    ] as CFDictionary)
                    index += 1
                    if index < count { progress(Double(index) / Double(count)) }
                }
            }
            guard index == count else {
                throw GIFEncoderError.frameFailed(String(localized: "Unbekannter Fehler"))
            }
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(output) else {
                throw GIFEncoderError.writeFailed(String(localized: "Unbekannter Fehler"))
            }
            try (data as Data).write(to: temp)
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            if error is CancellationError || error is GIFEncoderError { throw error }
            if FileManager.default.fileExists(atPath: destination.path) { throw GIFEncoderError.destinationExists }
            throw GIFEncoderError.writeFailed(error.localizedDescription)
        }
        progress(1.0)
    }

    /// The same picture as `image`, backed by lossless PNG data that is decoded only when ImageIO reads it,
    /// so an image the GIF destination holds on to costs the compressed size instead of the full bitmap.
    static func compactFrame(_ image: CGImage) throws -> CGImage {
        let data = NSMutableData()
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let png = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw GIFEncoderError.frameFailed(String(localized: "Unbekannter Fehler")) }
        CGImageDestinationAddImage(png, image, nil)
        guard CGImageDestinationFinalize(png),
              let source = CGImageSourceCreateWithData(data as CFData, noCache),
              let compact = CGImageSourceCreateImageAtIndex(source, 0, noCache)
        else { throw GIFEncoderError.frameFailed(String(localized: "Unbekannter Fehler")) }
        return compact
    }

    /// Delays for `count` frames at `fps`, in GIF units of 1/100 s. Each delay is rounded so the running sum
    /// after frame i is i/fps rounded to 1/100 s (the rounding error is carried, never accumulated): at
    /// 15 fps the delays alternate between 0.07 and 0.06 s and 45 frames last exactly 3.00 s.
    public static func frameDelays(fps: Int, count: Int) -> [Double] {
        guard fps > 0, count > 0 else { return [] }
        var delays: [Double] = []
        delays.reserveCapacity(count)
        var elapsed = 0
        for i in 1...count {
            // round(i × 100 / fps) in whole hundredths, half up, without floating point.
            let end = (i * 200 + fps) / (2 * fps)
            delays.append(Double(end - elapsed) / 100)
            elapsed = end
        }
        return delays
    }
}
