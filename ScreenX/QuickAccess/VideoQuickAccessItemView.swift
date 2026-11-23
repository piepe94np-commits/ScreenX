import AppKit
import AVFoundation
import ImageIO
import ScreenXCore
import SwiftUI

/// Zustand einer Videokarte (Video oder GIF), beobachtet von `VideoQuickAccessItemView`.
@MainActor @Observable
final class VideoQuickAccessItemModel {
    let url: URL
    let duration: TimeInterval
    let size: Int64
    var thumbnail: NSImage?
    var isHovered = false
    var isPinned = false

    var isGIF: Bool { url.pathExtension.lowercased() == "gif" }

    /// „52:07 · 1,9 GB“ bzw. „GIF · 0:08 · 3,2 MB“.
    var badge: String {
        let text = "\(VideoText.duration(duration)) · \(VideoText.size(size))"
        return isGIF ? "GIF · \(text)" : text
    }

    init(url: URL, duration: TimeInterval, size: Int64) {
        self.url = url
        self.duration = duration
        self.size = size
        Task { [weak self, url] in
            guard let image = await VideoFileInfo.thumbnail(url: url) else { return }
            self?.thumbnail = NSImage(cgImage: image, size: .zero)
        }
    }
}

/// Aktionen einer Videokarte; `trim == nil` blendet „Kürzen“ aus (GIF-Karten).
struct VideoQuickAccessActions {
    var open: () -> Void
    var trim: (() -> Void)?
    var reveal: () -> Void
    var delete: () -> Void
    var close: () -> Void
    var togglePin: () -> Void
    var makeDragFile: () throws -> URL
    var dragEnded: (_ dropped: Bool) -> Void
}

/// Vorschaukarte nach einer Videoaufnahme (Figma-Rahmen 4): Vorschaubild mit Dauer und Größe,
/// beim Überfahren Öffnen, Kürzen, Im Finder, Löschen. Herausziehen übergibt die Datei selbst.
struct VideoQuickAccessItemView: View {
    let model: VideoQuickAccessItemModel
    let actions: VideoQuickAccessActions

    var body: some View {
        card
            .frame(width: QuickAccessMetrics.cardSize.width, height: QuickAccessMetrics.cardSize.height)
            .padding(EdgeInsets(
                top: QuickAccessMetrics.margins.top,
                leading: QuickAccessMetrics.margins.left,
                bottom: QuickAccessMetrics.margins.bottom,
                trailing: QuickAccessMetrics.margins.right
            ))
            .animation(.easeOut(duration: 0.15), value: model.isHovered)
    }

    private var card: some View {
        thumbnail
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 16)
            )
            .overlay(alignment: .topLeading) {
                if model.isHovered {
                    QuickAccessButton.circle("xmark", label: String(localized: "Schließen"), action: actions.close)
                        .padding(6)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.isHovered || model.isPinned {
                    QuickAccessButton.circle(
                        model.isPinned ? "pin.fill" : "pin",
                        label: model.isPinned ? String(localized: "Lösen") : String(localized: "Anheften"),
                        action: actions.togglePin
                    )
                    .padding(6)
                    .transition(.opacity)
                }
            }
    }

    private var thumbnail: some View {
        ZStack {
            Color.black
            if let image = model.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .overlay {
            if !model.isGIF, !model.isHovered {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text(model.badge)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(6)
                .allowsHitTesting(false)
        }
        .overlay {
            ThumbnailDragView(
                image: model.thumbnail ?? Self.placeholder,
                makeFile: actions.makeDragFile,
                onClick: actions.open,
                onDragEnded: actions.dragEnded
            )
        }
        .overlay {
            if model.isHovered {
                Color.black.opacity(0.45)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.isHovered {
                VStack(spacing: 6) {
                    QuickAccessButton.action(String(localized: "Öffnen"), action: actions.open)
                    if let trim = actions.trim {
                        QuickAccessButton.action(String(localized: "Kürzen"), action: trim)
                    }
                    QuickAccessButton.action(String(localized: "Im Finder"), action: actions.reveal)
                    QuickAccessButton.action(String(localized: "Löschen"), tint: .red, action: actions.delete)
                }
                .transition(.opacity)
            }
        }
    }

    private static let placeholder = NSImage(size: NSSize(width: 240, height: 135))
}

/// Anzeigetexte für Videos, mit deutschem Dezimalkomma unabhängig von der Systemsprache.
enum VideoText {
    /// „0:08“, „52:07“, „1:02:03“; `padMinutes` ergibt „06:15“.
    static func duration(_ seconds: TimeInterval, padMinutes: Bool = false) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: padMinutes ? "%02d:%02d" : "%d:%02d", minutes, secs)
    }

    /// „1,9 GB“, „312 MB“, „3,2 MB“, „840 KB“ (Dezimaleinheiten).
    static func size(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000 { return number(value / 1_000_000_000, decimals: 1) + " GB" }
        if value >= 100_000_000 { return number(value / 1_000_000, decimals: 0) + " MB" }
        if value >= 1_000_000 { return number(value / 1_000_000, decimals: 1) + " MB" }
        return number(max(1, value / 1000), decimals: 0) + " KB"
    }

    /// Megabytes ohne Einheit: unter 10 mit einer Nachkommastelle.
    static func megabytes(_ value: Double) -> String {
        number(value, decimals: value >= 10 ? 0 : 1)
    }

    private static func number(_ value: Double, decimals: Int) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).locale(Locale(identifier: "de_DE")))
    }
}

/// Liest Vorschaubild, Dauer, Maße und Größe einer Video- oder GIF-Datei außerhalb des Main Actors.
enum VideoFileInfo {
    struct Info: Sendable {
        var duration: Double
        /// Anzeigegröße in Pixeln (mit `preferredTransform`).
        var displaySize: CGSize
    }

    static func info(url: URL) async -> Info? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            return Info(duration: duration.seconds, displaySize: CGSize(width: abs(rect.width), height: abs(rect.height)))
        } catch {
            return nil
        }
    }

    /// Bild bei 1 s (bei kürzeren Videos das erste); bei GIFs das erste Bild.
    static func thumbnail(url: URL) async -> CGImage? {
        if url.pathExtension.lowercased() == "gif" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 340)
        for seconds in [1.0, 0.0] {
            if let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                return result.image
            }
        }
        return nil
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func range(start: Double, end: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    /// `TrimExporter.export` mit einem Bereich in Sekunden.
    static func exportTrim(source: URL, start: Double, end: Double, to destination: URL) async throws {
        try await TrimExporter.export(source: source, range: range(start: start, end: end), to: destination)
    }

    /// `GIFEncoder.encode` mit einem Bereich in Sekunden.
    static func encodeGIF(
        source: URL, start: Double, end: Double, options: GIFOptions, to destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws {
        try await GIFEncoder.encode(
            source: source, range: range(start: start, end: end), options: options, to: destination,
            progress: progress
        )
    }
}
