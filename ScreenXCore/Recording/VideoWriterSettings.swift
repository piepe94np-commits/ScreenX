import AVFoundation
import CoreGraphics
import VideoToolbox

/// Encoder settings for `VideoFileWriter`: one video track plus up to two AAC audio tracks.
public struct VideoWriterSettings: Sendable, Equatable {
    /// Maximum distance between two keyframes.
    public static let keyFrameIntervalSeconds: Double = 2
    /// Fragment interval of the `.mov`, so a crashed recording stays readable up to the last fragment.
    public static let fragmentIntervalSeconds: Double = 10
    /// Hard upper bound for the video data rate, relative to the average bit rate (over windows of 1 s).
    public static let peakBitrateFactor = 1.5
    public static let audioSampleRate = 48_000
    public static let audioChannels = 2

    public var size: CGSize
    public var fps: Int
    public var codec: VideoCodec
    /// Average video bit rate in bit/s.
    public var bitrate: Int
    /// Number of audio tracks (0…2): system audio and microphone each get their own track.
    public var audioTracks: Int

    public init(size: CGSize, fps: Int, codec: VideoCodec, bitrate: Int, audioTracks: Int) {
        self.size = size
        self.fps = fps
        self.codec = codec
        self.bitrate = bitrate
        self.audioTracks = min(2, max(0, audioTracks))
    }

    public init(profile: RecordingProfile, targetSize: CGSize) {
        self.init(
            size: targetSize,
            fps: profile.fps,
            codec: profile.codec,
            bitrate: RecordingEstimate.videoBitrate(
                size: targetSize, fps: profile.fps, quality: profile.quality, codec: profile.codec),
            audioTracks: (profile.systemAudio ? 1 : 0) + (profile.microphone ? 1 : 0)
        )
    }

    /// Peak limit in bytes per second for `kVTCompressionPropertyKey_DataRateLimits`.
    var peakBytesPerSecond: Int { Int(Double(bitrate) * Self.peakBitrateFactor / 8) }

    /// Video output settings; with `dataRateLimit` the encoder also gets a hard peak data rate.
    func videoOutputSettings(dataRateLimit: Bool) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: Self.keyFrameIntervalSeconds,
        ]
        if dataRateLimit {
            compression[kVTCompressionPropertyKey_DataRateLimits as String] = [peakBytesPerSecond, 1.0] as [Any]
        }
        return [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    var audioOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.audioSampleRate,
            AVNumberOfChannelsKey: Self.audioChannels,
            AVEncoderBitRateKey: RecordingEstimate.audioBitrate,
        ]
    }
}
