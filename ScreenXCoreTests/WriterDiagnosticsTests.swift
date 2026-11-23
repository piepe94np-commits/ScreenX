import AVFoundation
import CoreMedia
import Testing
@testable import ScreenXCore

// TEMPORARY diagnostics for bitrate behaviour on CI; removed before the task is done.
@Suite(.serialized)
struct WriterDiagnosticsTests {
    func run(bitrate: Int, codec: VideoCodec, fresh: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = VideoWriterSettings(size: CGSize(width: 640, height: 360), fps: 30, codec: codec, bitrate: bitrate, audioTracks: 0)
        let writer = try VideoFileWriter(url: url, settings: s)
        let noise = SyntheticMedia.noiseFrame(width: 640, height: 360, seed: 1)
        var seed: UInt64 = 1
        await SyntheticMedia.record(writer, from: 0, to: 10, fps: 30) { _ in
            seed += 1
            return fresh ? SyntheticMedia.noiseFrame(width: 640, height: 360, seed: seed) : noise
        }
        _ = try await writer.finish(stopAt: SyntheticMedia.hostTime(10))
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        reader.startReading()
        var sizes: [Int] = []
        while let sb = out.copyNextSampleBuffer() { sizes.append(CMSampleBufferGetTotalSampleSize(sb)) }
        print("DIAG codec=\(codec) bitrate=\(bitrate) fresh=\(fresh) total=\(writer.bytesWritten) samples=\(sizes.count) dropped=\(writer.droppedBufferCount) first10=\(sizes.prefix(10)) big=\(sizes.enumerated().filter { $0.element > 20000 }.map { "\($0.offset):\($0.element)" }.prefix(20)) last5=\(sizes.suffix(5))")
    }

    @Test func diagnose() async throws {
        for b in [250_000, 414_720, 2_000_000] { try await run(bitrate: b, codec: .h264, fresh: false) }
        try await run(bitrate: 414_720, codec: .h264, fresh: true)
        try await run(bitrate: 248_832, codec: .hevc, fresh: false)
    }
}
