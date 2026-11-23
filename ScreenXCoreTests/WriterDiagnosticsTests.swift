import AVFoundation
import CoreMedia
import Testing
@testable import ScreenXCore

// TEMPORARY diagnostics for bitrate behaviour on CI; removed before the task is done.
@Suite(.serialized)
struct WriterDiagnosticsTests {
    func run(_ name: String, bitrate: Int, frame: (Int) -> CVPixelBuffer) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = VideoWriterSettings(size: CGSize(width: 640, height: 360), fps: 30, codec: .h264, bitrate: bitrate, audioTracks: 0)
        let writer = try VideoFileWriter(url: url, settings: s)
        await SyntheticMedia.record(writer, from: 0, to: 10, fps: 30) { t in frame(Int((t * 30).rounded())) }
        _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(10))
        print("DIAG \(name) bitrate=\(bitrate) total=\(writer.bytesWritten) ratio=\(Double(writer.bytesWritten) / (Double(bitrate) * 10 / 8)) dropped=\(writer.droppedBufferCount)")
    }

    @Test func diagnose() async throws {
        let w = 640, h = 360
        for b in [414_720, 40_000_000] {
            try await run("block8-static", bitrate: b) { _ in SyntheticMedia.blockNoiseFrame(width: w, height: h, block: 8, offset: 0) }
            try await run("block8-scroll4", bitrate: b) { i in SyntheticMedia.blockNoiseFrame(width: w, height: h, block: 8, offset: 4 * i) }
            try await run("block4-scroll4", bitrate: b) { i in SyntheticMedia.blockNoiseFrame(width: w, height: h, block: 4, offset: 4 * i) }
            try await run("block2-scroll2", bitrate: b) { i in SyntheticMedia.blockNoiseFrame(width: w, height: h, block: 2, offset: 2 * i) }
            try await run("block1-scroll1", bitrate: b) { i in SyntheticMedia.blockNoiseFrame(width: w, height: h, block: 1, offset: i) }
        }
    }
}
