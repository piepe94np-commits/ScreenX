import AVFoundation
import CoreMedia

public enum TrimExporterError: Error, Equatable, Sendable {
    /// The destination already exists; it is never overwritten.
    case destinationExists
    /// The destination extension is neither `.mp4` nor `.mov`.
    case unsupportedFileType
    /// The source could not be opened.
    case unreadable(String)
    /// The export itself failed.
    case exportFailed(String)
}

extension TrimExporterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .destinationExists:
            String(localized: "Es gibt bereits eine Datei mit diesem Namen.")
        case .unsupportedFileType:
            String(localized: "Dieses Dateiformat wird beim Kürzen nicht unterstützt.")
        case .unreadable(let reason):
            String(localized: "Das Video konnte nicht gelesen werden: \(reason)")
        case .exportFailed(let reason):
            String(localized: "Das gekürzte Video konnte nicht gespeichert werden: \(reason)")
        }
    }
}

/// Cuts a finished video to a time range without re-encoding.
public enum TrimExporter {
    /// Exports `range` of `source` to `destination` with `AVAssetExportPresetPassthrough`. The file type follows
    /// the destination extension (`.mp4` or `.mov`). Without re-encoding the cut snaps to keyframes, so the
    /// result can be slightly longer than `range`. The file is written under a hidden temporary name next to
    /// the destination and moved into place only when complete; an existing destination is never overwritten.
    public static func export(source: URL, range: CMTimeRange, to destination: URL) async throws {
        guard let fileType = fileType(for: destination) else { throw TrimExporterError.unsupportedFileType }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TrimExporterError.destinationExists
        }
        let asset = AVURLAsset(url: source)
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard !videoTracks.isEmpty else {
                throw TrimExporterError.unreadable(String(localized: "Die Datei enthält kein Video."))
            }
            let duration = try await asset.load(.duration)
            let span = range.intersection(CMTimeRange(start: .zero, duration: duration))
            guard span.duration.isValid, CMTimeCompare(span.duration, .zero) > 0 else {
                throw TrimExporterError.unreadable(String(localized: "Der gewählte Bereich liegt außerhalb des Videos."))
            }
        } catch let error as TrimExporterError {
            throw error
        } catch {
            throw TrimExporterError.unreadable(error.localizedDescription)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TrimExporterError.unreadable(String(localized: "Unbekannter Fehler"))
        }
        session.timeRange = range

        let temp = temporaryURL(for: destination, purpose: "trimming")
        do {
            try await session.export(to: temp, as: fileType)
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            if error is CancellationError { throw error }
            if FileManager.default.fileExists(atPath: destination.path) { throw TrimExporterError.destinationExists }
            throw TrimExporterError.exportFailed(error.localizedDescription)
        }
    }

    /// "<Name> gekürzt.<ext>" next to `source`, or "<Name> gekürzt 2.<ext>", 3, … for the first free name.
    /// The extension of the source is kept.
    public static func trimmedURL(for source: URL) -> URL {
        let directory = source.deletingLastPathComponent()
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        var counter = 1
        while true {
            let base = counter == 1 ? "\(name) gekürzt" : "\(name) gekürzt \(counter)"
            let candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private static func fileType(for url: URL) -> AVFileType? {
        switch url.pathExtension.lowercased() {
        case "mp4": .mp4
        case "mov": .mov
        default: nil
        }
    }

    /// Hidden file next to `destination` with the same extension, e.g. ".Clip.trimming.mp4".
    static func temporaryURL(for destination: URL, purpose: String) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            "." + destination.deletingPathExtension().lastPathComponent + "." + purpose + "."
                + UUID().uuidString.prefix(8) + "." + destination.pathExtension)
    }
}
