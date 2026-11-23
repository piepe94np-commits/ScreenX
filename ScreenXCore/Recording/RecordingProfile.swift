import Foundation

public enum VideoResolution: String, Codable, CaseIterable, Sendable {
    case original, p1440, p1080, p720, p480

    /// Upper bound for the longer side in pixels; `nil` means unlimited.
    public var maxLongSide: Int? {
        switch self {
        case .original: nil
        case .p1440: 2560
        case .p1080: 1920
        case .p720: 1280
        case .p480: 854
        }
    }
}

public enum VideoQuality: String, Codable, CaseIterable, Sendable {
    case high, medium, small
}

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case hevc, h264
}

public enum RecordingOutput: String, Codable, Sendable {
    case video, gif
}

public struct RecordingProfile: Codable, Hashable, Sendable, Identifiable {
    public static let allowedFPS = [60, 30, 24, 15, 10]
    public static let defaultID = "meeting"

    public var id: String
    public var name: String
    public var resolution: VideoResolution
    public var fps: Int
    public var quality: VideoQuality
    public var codec: VideoCodec
    public var showsCursor: Bool
    public var highlightClicks: Bool
    public var systemAudio: Bool
    public var microphone: Bool
    public var output: RecordingOutput

    public init(
        id: String,
        name: String,
        resolution: VideoResolution = .p1080,
        fps: Int = 24,
        quality: VideoQuality = .medium,
        codec: VideoCodec = .hevc,
        showsCursor: Bool = true,
        highlightClicks: Bool = false,
        systemAudio: Bool = false,
        microphone: Bool = false,
        output: RecordingOutput = .video
    ) {
        self.id = id
        self.name = name
        self.resolution = resolution
        self.fps = Self.nearestAllowedFPS(fps)
        self.quality = quality
        self.codec = codec
        self.showsCursor = showsCursor
        self.highlightClicks = highlightClicks
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.output = output
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, resolution, fps, quality, codec, showsCursor, highlightClicks
        case systemAudio, microphone, output
    }

    /// Tolerant decoding: missing or unreadable fields get defaults; an invalid `fps`
    /// is mapped to the nearest allowed value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Profil"
        resolution = (try? c.decodeIfPresent(VideoResolution.self, forKey: .resolution)) ?? .p1080
        fps = Self.nearestAllowedFPS((try? c.decodeIfPresent(Int.self, forKey: .fps)) ?? 24)
        quality = (try? c.decodeIfPresent(VideoQuality.self, forKey: .quality)) ?? .medium
        codec = (try? c.decodeIfPresent(VideoCodec.self, forKey: .codec)) ?? .hevc
        showsCursor = (try? c.decodeIfPresent(Bool.self, forKey: .showsCursor)) ?? true
        highlightClicks = (try? c.decodeIfPresent(Bool.self, forKey: .highlightClicks)) ?? false
        systemAudio = (try? c.decodeIfPresent(Bool.self, forKey: .systemAudio)) ?? false
        microphone = (try? c.decodeIfPresent(Bool.self, forKey: .microphone)) ?? false
        output = (try? c.decodeIfPresent(RecordingOutput.self, forKey: .output)) ?? .video
    }

    static func nearestAllowedFPS(_ fps: Int) -> Int {
        // Ties resolve to the lower value (allowedFPS is descending, `<` keeps the later one).
        allowedFPS.reduce(allowedFPS[0]) { best, candidate in
            abs(candidate - fps) <= abs(best - fps) ? candidate : best
        }
    }

    public static let builtins: [RecordingProfile] = [
        RecordingProfile(id: "meeting", name: "Meeting", resolution: .p1080, fps: 24, quality: .medium,
                         codec: .hevc, systemAudio: true, microphone: true),
        RecordingProfile(id: "presentation", name: "Präsentation", resolution: .p1080, fps: 15, quality: .medium,
                         codec: .hevc, systemAudio: false, microphone: true),
        RecordingProfile(id: "demo", name: "Demo (scharf)", resolution: .original, fps: 60, quality: .high,
                         codec: .hevc),
        RecordingProfile(id: "gif", name: "GIF", resolution: .p480, fps: 10, quality: .small,
                         codec: .h264, output: .gif),
    ]
}
