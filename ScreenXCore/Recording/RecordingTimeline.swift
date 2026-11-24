import CoreMedia

/// Pure time arithmetic for a recording: maps host-clock times (as delivered by ScreenCaptureKit)
/// to output file times, with pauses removed so picture and sound stay in sync and no gap remains.
public struct RecordingTimeline: Sendable {
    /// Host time of the first video frame; `nil` until the first frame arrives.
    private var origin: CMTime?
    /// Total host time spent paused so far (completed pauses only).
    private var pausedTotal: CMTime = .zero
    /// Host time at which the current pause began; `nil` while recording.
    private var pauseStart: CMTime?
    /// Host time at which the last pause ended; used to drop buffers that straddle the boundary.
    private var lastResume: CMTime?

    public init() {}

    public var isPaused: Bool { pauseStart != nil }

    /// Recorded (non-paused) time so far, up to the latest pause start or resume; zero before the first frame.
    public var activeDuration: CMTime {
        guard let origin else { return .zero }
        let end = pauseStart ?? latest
        return max(.zero, CMTimeSubtract(CMTimeSubtract(end, origin), pausedTotal))
    }

    /// Latest host time seen (video/audio/resume); the end of the active span while not paused.
    private var latest: CMTime = .zero

    /// Output time for a video frame, or `nil` while paused. The first call sets the origin.
    public mutating func video(at hostTime: CMTime) -> CMTime? {
        if isPaused { return nil }
        if origin == nil { origin = hostTime }
        guard let origin else { return nil }
        if let lastResume, CMTimeCompare(hostTime, lastResume) < 0 { return nil }
        advance(to: hostTime)
        return max(.zero, CMTimeSubtract(CMTimeSubtract(hostTime, origin), pausedTotal))
    }

    /// Output time for an audio buffer, or `nil` before the first video frame, while paused, or when
    /// the buffer starts before the origin or intersects a pause boundary (it is dropped entirely).
    public mutating func audio(at hostTime: CMTime, duration: CMTime) -> CMTime? {
        guard let origin, !isPaused else { return nil }
        if CMTimeCompare(hostTime, origin) < 0 { return nil }
        if let lastResume, CMTimeCompare(hostTime, lastResume) < 0 { return nil }
        advance(to: CMTimeAdd(hostTime, duration))
        return max(.zero, CMTimeSubtract(CMTimeSubtract(hostTime, origin), pausedTotal))
    }

    /// Starts a pause. No-op if already paused or before the first frame.
    public mutating func pause(at hostTime: CMTime) {
        guard origin != nil, !isPaused else { return }
        advance(to: hostTime)
        pauseStart = hostTime
    }

    /// Ends a pause, adding its length to the offset. No-op if not paused.
    public mutating func resume(at hostTime: CMTime) {
        guard let start = pauseStart else { return }
        pausedTotal = CMTimeAdd(pausedTotal, max(.zero, CMTimeSubtract(hostTime, start)))
        pauseStart = nil
        lastResume = hostTime
        latest = hostTime
    }

    /// Session end for a stop at `hostTime`, so the last frame is held until the stop.
    public func outputTime(forStopAt hostTime: CMTime) -> CMTime {
        guard let origin else { return .zero }
        let end = pauseStart ?? hostTime
        let paused = pausedTotal
        return max(.zero, CMTimeSubtract(CMTimeSubtract(end, origin), paused))
    }

    private mutating func advance(to hostTime: CMTime) {
        if CMTimeCompare(hostTime, latest) > 0 { latest = hostTime }
    }
}
