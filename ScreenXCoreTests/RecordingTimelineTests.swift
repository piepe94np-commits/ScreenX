import CoreMedia
import Testing
@testable import ScreenXCore

struct RecordingTimelineTests {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1000) }
    private let dur = CMTime(value: 21, timescale: 1000)

    @Test func firstVideoFrameIsZero() {
        var tl = RecordingTimeline()
        #expect(tl.video(at: t(10)) == .zero)
        #expect(tl.video(at: t(10.5)) == t(0.5))
        #expect(!tl.isPaused)
    }

    @Test func pausesLeaveNoGapAndKeepAudioInSync() {
        var tl = RecordingTimeline()
        _ = tl.video(at: t(10))
        _ = tl.video(at: t(11))
        tl.pause(at: t(12))
        #expect(tl.isPaused)
        #expect(tl.video(at: t(15)) == nil)
        #expect(tl.audio(at: t(15), duration: dur) == nil)
        tl.resume(at: t(20))
        #expect(!tl.isPaused)
        #expect(tl.video(at: t(21)) == t(3))
        #expect(tl.audio(at: t(21), duration: dur) == t(3))
        #expect(tl.outputTime(forStopAt: t(23)) == t(5))
        #expect(tl.activeDuration == t(3.021))  // up to the end of the last audio buffer
    }

    @Test func audioBeforeFirstFrameDroppedAndAligned() {
        var tl = RecordingTimeline()
        #expect(tl.audio(at: t(9.5), duration: dur) == nil)
        _ = tl.video(at: t(10))
        #expect(tl.audio(at: t(9.98), duration: dur) == nil)
        #expect(tl.audio(at: t(10.04), duration: dur) == t(0.04))
    }

    @Test func audioStraddlingPauseBoundaryIsDropped() {
        var tl = RecordingTimeline()
        _ = tl.video(at: t(10))
        tl.pause(at: t(12))
        tl.resume(at: t(20))
        #expect(tl.audio(at: t(19.99), duration: dur) == nil)
        #expect(tl.audio(at: t(20), duration: dur) == t(2))  // 10...12 was active, 12...20 paused
    }

    @Test func multiplePauses() {
        var tl = RecordingTimeline()
        _ = tl.video(at: t(0))
        tl.pause(at: t(2))
        tl.resume(at: t(5))   // 3 s paused
        #expect(tl.video(at: t(6)) == t(3))
        tl.pause(at: t(8))
        tl.resume(at: t(10))  // 2 s paused
        #expect(tl.video(at: t(11)) == t(6))
        #expect(tl.outputTime(forStopAt: t(12)) == t(7))
        #expect(tl.activeDuration == t(6))  // up to the last frame seen
    }

    @Test func pauseWhilePausedIsNoOp() {
        var tl = RecordingTimeline()
        _ = tl.video(at: t(0))
        tl.pause(at: t(2))
        tl.pause(at: t(4))   // must not move the pause start
        tl.resume(at: t(5))
        #expect(tl.video(at: t(6)) == t(3))
        tl.resume(at: t(7))  // resume while running is a no-op too
        #expect(tl.video(at: t(8)) == t(5))
    }

    @Test func stopWhilePausedEndsAtPauseStart() {
        var tl = RecordingTimeline()
        _ = tl.video(at: t(10))
        tl.pause(at: t(12))
        #expect(tl.outputTime(forStopAt: t(30)) == t(2))
    }
}
