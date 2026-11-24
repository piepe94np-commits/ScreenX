import CoreGraphics
import Foundation
import Testing
@testable import ScreenXCore

struct RecordingProfileTests {
    @Test func builtinsMatchSpec() {
        let b = RecordingProfile.builtins
        #expect(b.map(\.id) == ["meeting", "presentation", "demo", "gif"])
        #expect(b.map(\.name) == ["Meeting", "Präsentation", "Demo (scharf)", "GIF"])
        #expect(b.map(\.resolution) == [.p1080, .p1080, .original, .p480])
        #expect(b.map(\.fps) == [24, 15, 60, 10])
        #expect(b.map(\.quality) == [.medium, .medium, .high, .small])
        #expect(b.map(\.codec) == [.hevc, .hevc, .hevc, .h264])
        #expect(b.map(\.systemAudio) == [true, false, false, false])
        #expect(b.map(\.microphone) == [true, true, false, false])
        #expect(b.map(\.output) == [.video, .video, .video, .gif])
        #expect(b.allSatisfy { $0.showsCursor && !$0.highlightClicks })
        #expect(RecordingProfile.defaultID == "meeting")
    }

    @Test func targetSizeEvenNeverUpscaledMinimum() {
        #expect(RecordingEstimate.targetSize(source: CGSize(width: 2940, height: 1912), resolution: .p1080)
            == CGSize(width: 1920, height: 1248))
        #expect(RecordingEstimate.targetSize(source: CGSize(width: 1000, height: 600), resolution: .p1080)
            == CGSize(width: 1000, height: 600))
        #expect(RecordingEstimate.targetSize(source: CGSize(width: 301, height: 7), resolution: .original)
            == CGSize(width: 300, height: 6))
        #expect(RecordingEstimate.targetSize(source: CGSize(width: 1, height: 1), resolution: .original)
            == CGSize(width: 2, height: 2))
        #expect(RecordingEstimate.targetSize(source: CGSize(width: 1912, height: 2940), resolution: .p720)
            == CGSize(width: 832, height: 1280))
    }

    @Test func bitrateFormulaAndClamp() {
        let a = RecordingEstimate.videoBitrate(size: CGSize(width: 1920, height: 1080), fps: 24, quality: .medium, codec: .hevc)
        #expect(abs(a - 1_791_590) <= 1)
        #expect(RecordingEstimate.videoBitrate(size: CGSize(width: 7680, height: 4320), fps: 60, quality: .high, codec: .h264) == 40_000_000)
        #expect(RecordingEstimate.videoBitrate(size: CGSize(width: 320, height: 240), fps: 10, quality: .small, codec: .hevc) == 250_000)
    }

    @Test func estimateText() {
        #expect(RecordingEstimate.text(megabytesPerMinute: 38.2) == "≈ 38 MB/min · ≈ 2,3 GB/h")
        #expect(RecordingEstimate.text(megabytesPerMinute: 0.4) == "≈ 0,4 MB/min · ≈ 24 MB/h")
    }

    @Test func estimateIncludesAudioOnce() {
        let meeting = RecordingProfile.builtins[0]
        let mb = RecordingEstimate.megabytesPerMinute(profile: meeting, source: CGSize(width: 1920, height: 1080))
        #expect(abs(mb - (1_791_590.0 + 128_000) * 60 / 8 / 1e6) < 0.001)
        #expect(abs(mb - 14.4) < 0.05)
    }

    @Test func profileTolerantDecoding() throws {
        let p = try JSONDecoder().decode(RecordingProfile.self, from: Data(#"{"id":"x","name":"X"}"#.utf8))
        #expect(p.id == "x" && p.name == "X")
        #expect(p.resolution == .p1080 && p.fps == 24 && p.quality == .medium && p.codec == .hevc)
        #expect(p.showsCursor && !p.highlightClicks && !p.systemAudio && !p.microphone && p.output == .video)
        let q = try JSONDecoder().decode(RecordingProfile.self, from: Data(#"{"id":"x","name":"X","fps":25}"#.utf8))
        #expect(q.fps == 24)
    }
}
