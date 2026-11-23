import CoreMedia
import Testing
@testable import ScreenXCore

struct AudioNormalizerTests {
    private let bufferSeconds = Double(SyntheticMedia.audioFrames) / 48_000

    /// Output times for input buffer `k`: drifting (+1000 ppm), a 2 s stall, a straddle overlap and a
    /// large backward jump.
    private func inputTimes() -> [Double] {
        var times: [Double] = []
        var t = 0.3  // starts late: leading silence
        for k in 0..<400 {
            times.append(t)
            t += bufferSeconds * 1.001
            if k == 100 { t += 2 }                 // stall
            if k == 200 { t -= 0.005 }             // straddle: small overlap
            if k == 300 { t -= 0.05 }              // backward jump beyond the threshold
        }
        return times
    }

    @Test func outputIsContiguousAndNeverOverlaps() throws {
        let normalizer = AudioNormalizer()
        var previousEnd = CMTime.zero
        var outputs = 0
        for (k, t) in inputTimes().enumerated() {
            let buffer = SyntheticMedia.sineBuffer(startSample: Int64(k * SyntheticMedia.audioFrames))
            let time = CMTime(seconds: t, preferredTimescale: 1_000_000_000)
            guard case .output(let silence, let data, let start) = normalizer.convert(buffer, at: time) else {
                continue
            }
            outputs += 1
            if let silence {
                #expect(CMTimeCompare(silence.start, previousEnd) == 0, "buffer \(k)")
                let silenceEnd = CMTimeAdd(silence.start, CMTime(value: CMTimeValue(silence.frames), timescale: 48_000))
                #expect(CMTimeCompare(start, silenceEnd) == 0, "buffer \(k)")
            }
            #expect(CMTimeCompare(start, previousEnd) >= 0, "buffer \(k)")
            #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(data), start) == 0, "buffer \(k)")
            previousEnd = CMTimeAdd(start, CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(data)),
                                                  timescale: 48_000))
        }
        #expect(outputs > 390)
        #expect(normalizer.resyncs >= 3)
        #expect(normalizer.trimmedFrames > 0)
        #expect(normalizer.silenceFrames > 2 * 48_000)
    }
}
