import AVFoundation
import CoreMedia
import os

public enum RecordingFinalizerError: Error, Equatable, Sendable {
    /// The `.mov` could not be opened or read.
    case unreadable(String)
    /// The `.mov` has no video track.
    case noVideo
    /// A file with the final name already exists; it is never overwritten.
    case destinationExists
    /// Writing the `.mp4` failed.
    case writeFailed(String)
}

extension RecordingFinalizerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            String(localized: "Die Aufnahme konnte nicht gelesen werden: \(reason)")
        case .noVideo:
            String(localized: "Die Aufnahme enthält kein Video.")
        case .destinationExists:
            String(localized: "Es gibt bereits eine fertige Datei mit diesem Namen.")
        case .writeFailed(let reason):
            String(localized: "Die Aufnahme konnte nicht fertiggestellt werden: \(reason)")
        }
    }
}

/// Turns the `.mov` of `VideoFileWriter` into the final `.mp4` and finds recordings left over after a crash.
public enum RecordingFinalizer {
    /// Name prefix of recording files (`ScreenX Aufnahme JJJJ-MM-TT um HH.MM.SS.mov`).
    public static let filePrefix = "ScreenX Aufnahme "

    private static let log = Logger(subsystem: "com.screenx.app", category: "RecordingFinalizer")

    /// The `.mp4` next to `mov`, with the same name.
    public static func finalURL(for mov: URL) -> URL {
        mov.deletingPathExtension().appendingPathExtension("mp4")
    }

    /// Recordings (`ScreenX Aufnahme *.mov`) in `directory` without a `.mp4` of the same name, sorted by
    /// name. `excluding` lets the caller skip files that are still being written (the active recording).
    public static func leftovers(in directory: URL, excluding: Set<URL> = []) -> [URL] {
        let excluded = Set(excluding.map { $0.resolvingSymlinksInPath().path })
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { url in
                url.lastPathComponent.hasPrefix(filePrefix)
                    && url.pathExtension.lowercased() == "mov"
                    && !excluded.contains(url.resolvingSymlinksInPath().path)
                    && !FileManager.default.fileExists(atPath: finalURL(for: url).path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Writes `finalURL(for: mov)`: the video is passed through unchanged (codec, colour tags), all audio
    /// tracks are mixed into one AAC track (48 kHz stereo, 128 kbit/s). The `.mp4` is written under a
    /// hidden temporary name next to the target and moved into place only when complete; the `.mov` is
    /// deleted only after that. On failure the `.mov` stays, no `.mp4` is left behind, and the error is thrown.
    public static func finalize(mov: URL) async throws -> URL {
        let target = finalURL(for: mov)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw RecordingFinalizerError.destinationExists
        }
        let temp = mov.deletingLastPathComponent().appendingPathComponent(
            "." + mov.deletingPathExtension().lastPathComponent + ".finalizing.mp4")
        try? FileManager.default.removeItem(at: temp)
        do {
            try await transcode(mov: mov, to: temp)
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            if let error = error as? RecordingFinalizerError { throw error }
            throw RecordingFinalizerError.writeFailed(error.localizedDescription)
        }
        do {
            try FileManager.default.removeItem(at: mov)
        } catch {
            // The .mp4 is complete; a .mov that cannot be deleted is no reason to fail.
            log.error("Could not delete \(mov.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return target
    }

    // MARK: - Transcoding

    private static func transcode(mov: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: mov)
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        let duration: CMTime
        let formatHint: CMFormatDescription?
        let transform: CGAffineTransform
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
            guard let video = videoTracks.first else { throw RecordingFinalizerError.noVideo }
            formatHint = try await video.load(.formatDescriptions).first
            transform = try await video.load(.preferredTransform)
        } catch let error as RecordingFinalizerError {
            throw error
        } catch {
            throw RecordingFinalizerError.unreadable(error.localizedDescription)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw RecordingFinalizerError.unreadable(error.localizedDescription)
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTracks[0], outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw RecordingFinalizerError.unreadable(unknown) }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let mix = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: VideoWriterSettings.audioSampleRate,
                AVNumberOfChannelsKey: VideoWriterSettings.audioChannels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            mix.alwaysCopiesSampleData = false
            guard reader.canAdd(mix) else { throw RecordingFinalizerError.unreadable(unknown) }
            reader.add(mix)
            audioOutput = mix
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw RecordingFinalizerError.writeFailed(error.localizedDescription)
        }
        // No "fast start" rewrite: it leaves a hidden `.sb-…` helper file next to the output on finish.
        writer.shouldOptimizeForNetworkUse = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw RecordingFinalizerError.writeFailed(unknown) }
        writer.add(videoInput)
        var pumpList = [TrackPump(input: videoInput, output: videoOutput, label: "video")]
        if let audioOutput {
            let settings = VideoWriterSettings.aacOutputSettings
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
                throw RecordingFinalizerError.writeFailed(unknown)
            }
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            guard writer.canAdd(audioInput) else { throw RecordingFinalizerError.writeFailed(unknown) }
            writer.add(audioInput)
            pumpList.append(TrackPump(input: audioInput, output: audioOutput, label: "audio"))
        }
        let pumps = pumpList

        guard reader.startReading() else {
            throw RecordingFinalizerError.unreadable(reader.error?.localizedDescription ?? unknown)
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw RecordingFinalizerError.writeFailed(writer.error?.localizedDescription ?? unknown)
        }
        writer.startSession(atSourceTime: .zero)

        // Each track is pumped on its own queue so the writer can interleave them freely. If one append
        // fails, the others are stopped too: a failed writer may never ask them for more data.
        let appendsSucceeded = await withTaskGroup(of: Bool.self) { group in
            for pump in pumps { group.addTask { await pump.run() } }
            var all = true
            for await succeeded in group where !succeeded {
                all = false
                pumps.forEach { $0.abort() }
            }
            return all
        }
        guard appendsSucceeded, reader.status == .completed else {
            let readerFailed = reader.status == .failed
            let reason = (readerFailed ? reader.error : writer.error)?.localizedDescription ?? unknown
            reader.cancelReading()
            writer.cancelWriting()
            throw readerFailed ? RecordingFinalizerError.unreadable(reason) : RecordingFinalizerError.writeFailed(reason)
        }
        // Keep the length of the .mov (its last frame is held until the stop time).
        if duration.isValid, CMTimeCompare(duration, .zero) > 0 {
            writer.endSession(atSourceTime: duration)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw RecordingFinalizerError.writeFailed(writer.error?.localizedDescription ?? unknown)
        }
    }

    private static var unknown: String { String(localized: "Unbekannter Fehler") }
}

/// Copies the samples of one reader output into one writer input until the output is exhausted.
///
/// `@unchecked Sendable`: the input, the output and `done` are only touched on the private serial `queue`
/// (the `requestMediaDataWhenReady` block, `run` and `abort` all run there).
private final class TrackPump: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let output: AVAssetReaderOutput
    private let queue: DispatchQueue
    private var continuation: CheckedContinuation<Bool, Never>?
    private var done = false

    init(input: AVAssetWriterInput, output: AVAssetReaderOutput, label: String) {
        self.input = input
        self.output = output
        queue = DispatchQueue(label: "com.screenx.app.finalizer.\(label)")
    }

    /// Returns true when every sample was appended (or the output ended), false when an append failed
    /// or the pump was aborted.
    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.done else {
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                self.input.requestMediaDataWhenReady(on: self.queue) { self.pump() }
            }
        }
    }

    func abort() {
        queue.async { self.complete(false) }
    }

    private func pump() {
        while !done, input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                complete(true)
                return
            }
            // Readers also yield marker buffers without samples; they carry nothing to write.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            if !input.append(sample) {
                complete(false)
                return
            }
        }
    }

    private func complete(_ succeeded: Bool) {
        guard !done else { return }
        done = true
        continuation?.resume(returning: succeeded)
        continuation = nil
    }
}
