import CoreGraphics
import Foundation

public enum RecordingEstimate {
    static let audioBitrate = 128_000
    static let minBitrate = 250_000
    static let maxBitrate = 40_000_000
    /// Measured with dense scrolling text (0.16 bytes per pixel and frame) and solid colours (0.001); every
    /// GIF frame is stored in full, so text-heavy screens cost about the same per frame, static or not.
    static let gifBytesPerPixelFrame = 0.12

    /// Scales `source` so the longer side fits the resolution step (never upscaling),
    /// then rounds both sides down to even values of at least 2.
    public static func targetSize(source: CGSize, resolution: VideoResolution) -> CGSize {
        var w = Double(source.width)
        var h = Double(source.height)
        if let limit = resolution.maxLongSide.map(Double.init), max(w, h) > limit {
            // Set the longer side exactly to the limit to avoid floating-point drift.
            if w >= h {
                h = h * limit / w
                w = limit
            } else {
                w = w * limit / h
                h = limit
            }
        }
        return CGSize(width: even(w), height: even(h))
    }

    private static func even(_ v: Double) -> Int {
        max(2, Int(v / 2) * 2)
    }

    public static func videoBitrate(size: CGSize, fps: Int, quality: VideoQuality, codec: VideoCodec) -> Int {
        let factor: Double
        switch (codec, quality) {
        case (.h264, .high): factor = 0.10
        case (.h264, .medium): factor = 0.06
        case (.h264, .small): factor = 0.035
        case (.hevc, .high): factor = 0.06
        case (.hevc, .medium): factor = 0.036
        case (.hevc, .small): factor = 0.021
        }
        let raw = Double(size.width) * Double(size.height) * Double(fps) * factor
        return min(maxBitrate, max(minBitrate, Int(raw)))
    }

    public static func megabytesPerMinute(profile: RecordingProfile, source: CGSize) -> Double {
        let size = targetSize(source: source, resolution: profile.resolution)
        let video = videoBitrate(size: size, fps: profile.fps, quality: profile.quality, codec: profile.codec)
        // Several audio sources are mixed into a single track, so audio counts once.
        let hasAudio = profile.systemAudio || profile.microphone
        let bits = video + (hasAudio ? audioBitrate : 0)
        return Double(bits) * 60 / 8 / 1_000_000
    }

    /// Display text such as "≈ 38 MB/min · ≈ 2,3 GB/h" (German decimal comma regardless of locale).
    public static func text(megabytesPerMinute mbPerMin: Double) -> String {
        let perMin = mbPerMin >= 10 ? number(mbPerMin, decimals: 0) : number(mbPerMin, decimals: 1)
        let perHourMB = mbPerMin * 60
        let perHour = perHourMB >= 1000
            ? number(perHourMB / 1000, decimals: 1) + " GB/h"
            : number(perHourMB, decimals: 0) + " MB/h"
        return "≈ \(perMin) MB/min · ≈ \(perHour)"
    }

    public static func gifMegabytes(size: CGSize, fps: Int, seconds: Double) -> Double {
        Double(size.width) * Double(size.height) * Double(fps) * seconds * gifBytesPerPixelFrame / 1_000_000
    }

    private static func number(_ v: Double, decimals: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
