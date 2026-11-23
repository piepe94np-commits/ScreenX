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
        try await run("block3-scroll3", bitrate: 414_720) { i in SyntheticMedia.blockNoiseFrame(width: 640, height: 360, block: 3, offset: 3 * i) }
        try await run("block3-scroll3", bitrate: 40_000_000) { i in SyntheticMedia.blockNoiseFrame(width: 640, height: 360, block: 3, offset: 3 * i) }
    }
}
