import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import ScreenXCore

/// Synthetic capture buffers for writer tests: BGRA frames and a 48 kHz stereo sine tone with
/// host-time-like timestamps (recording time `t` maps to host time `baseSeconds + t`).
enum SyntheticMedia {
    static let baseSeconds: Int64 = 1000
    static let audioFrames = 1024

    /// Distinct colors (RGB); the frame color changes every second of recording time.
    static let palette: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (220, 30, 30), (30, 200, 30), (30, 30, 220), (220, 220, 30), (30, 220, 220),
        (220, 30, 220), (240, 240, 240), (255, 140, 0), (20, 20, 20), (120, 120, 120),
    ]

    static func colorIndex(at t: Double) -> Int { Int(t.rounded(.down)) % palette.count }

    /// Host time of a video frame, nanosecond timescale like ScreenCaptureKit.
    static func hostTime(_ t: Double) -> CMTime {
        CMTime(value: baseSeconds * 1_000_000_000 + Int64((t * 1e9).rounded()), timescale: 1_000_000_000)
    }

    static let canEncodeHEVC: Bool = {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 640, height: 360, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }()

    static func solidFrame(width: Int, height: Int, colorIndex: Int) -> CVPixelBuffer {
        let c = palette[colorIndex]
        let pixel = UInt32(c.b) | UInt32(c.g) << 8 | UInt32(c.r) << 16 | 0xFF00_0000
        return pixelBuffer(width: width, height: height) { row, _ in
            row.initialize(repeating: pixel, count: width)
        }
    }

    /// Full-resolution random BGR noise; a different `seed` gives a completely new picture (worst case).
    static func noiseFrame(width: Int, height: Int, seed: UInt64) -> CVPixelBuffer {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return pixelBuffer(width: width, height: height) { row, _ in
            for x in 0..<width {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                row[x] = UInt32(truncatingIfNeeded: state) | 0xFF00_0000
            }
        }
    }

    /// A tall white page with dense rows of small black glyph-like rectangles (2–3 px tall, a row every
    /// 12 px), generated once; `frame(offset:)` shows the window starting `offset` rows down (scrolling text).
    struct ScrollingText {
        let width: Int
        let height: Int
        private let pageHeight: Int
        private let pixels: [UInt32]

        init(width: Int, height: Int, maxOffset: Int, seed: UInt64 = 7) {
            self.width = width
            self.height = height
            pageHeight = height + maxOffset
            var page = [UInt32](repeating: 0xFFFF_FFFF, count: width * pageHeight)
            var state = seed | 1
            func next(_ range: ClosedRange<Int>) -> Int {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                return range.lowerBound + Int(state % UInt64(range.count))
            }
            for top in stride(from: 4, to: pageHeight - 4, by: 12) {
                var x = next(4...16)
                while x < width - 4 {
                    let glyphWidth = next(1...4)
                    let glyphHeight = next(2...3)
                    let yOffset = next(0...1)
                    for y in (top + yOffset)..<(top + yOffset + glyphHeight) {
                        for gx in x..<min(width, x + glyphWidth) { page[y * width + gx] = 0xFF00_0000 }
                    }
                    x += glyphWidth + (next(0...5) == 0 ? next(4...8) : next(1...2))
                }
            }
            pixels = page
        }

        func frame(offset: Int) -> CVPixelBuffer {
            pixelBuffer(width: width, height: height) { row, y in
                pixels.withUnsafeBufferPointer { page in
                    row.update(from: page.baseAddress! + (y + offset) * width, count: width)
                }
            }
        }
    }

    /// Gray noise made of `block`×`block` cells, shifted left by `offset` pixels (a scrolling detailed screen).
    static func blockNoiseFrame(width: Int, height: Int, block: Int, offset: Int, seed: UInt64 = 1) -> CVPixelBuffer {
        pixelBuffer(width: width, height: height) { row, y in
            for x in 0..<width {
                var h = UInt64((x + offset) / block) &* 0x9E37_79B9_7F4A_7C15
                    ^ UInt64(y / block) &* 0xC2B2_AE3D_27D4_EB4F ^ seed
                h ^= h >> 29
                h = h &* 0xBF58_476D_1CE4_E5B9
                h ^= h >> 32
                let g = UInt32(h & 0xFF)
                row[x] = g | g << 8 | g << 16 | 0xFF00_0000
            }
        }
    }

    fileprivate static func pixelBuffer(
        width: Int, height: Int, fillRow: (UnsafeMutablePointer<UInt32>, Int) -> Void
    ) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            let row = (base + y * bytesPerRow).bindMemory(to: UInt32.self, capacity: width)
            fillRow(row, y)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// Linear PCM float32 layout of synthetic sine buffers.
    struct SineFormat {
        var sampleRate: Int = 48_000
        var channels: Int = 2
        var interleaved = true

        static let stereo48k = SineFormat()
        static let mono48k = SineFormat(channels: 1)
        static let mono44k = SineFormat(sampleRate: 44_100, channels: 1)
        static let planarStereo48k = SineFormat(interleaved: false)
        /// Four channels and no channel layout.
        static let quad48k = SineFormat(channels: 4)
    }

    /// Float32 sine (440 Hz) of `frames` frames starting at sample `startSample` of recording time,
    /// in `format`, without a channel layout.
    static func sineBuffer(startSample: Int64, frames: Int = audioFrames,
                           format sine: SineFormat = .stereo48k, pts explicitPTS: CMTime? = nil) -> CMSampleBuffer {
        let channels = sine.channels
        let bytesPerFrame = UInt32(sine.interleaved ? 4 * channels : 4)
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if !sine.interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sine.sampleRate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

        // Interleaved: frame-major; non-interleaved: one plane per channel, back to back.
        var samples = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            let n = Double(startSample + Int64(i))
            let v = Float(sin(2 * Double.pi * 440 * n / Double(sine.sampleRate)) * 0.3)
            for c in 0..<channels {
                samples[sine.interleaved ? i * channels + c : c * frames + i] = v
            }
        }
        let byteCount = samples.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
        }
        let rate = Int64(sine.sampleRate)
        let pts = explicitPTS ?? CMTime(value: baseSeconds * rate + startSample, timescale: CMTimeScale(rate))
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: format!,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        return sampleBuffer!
    }

    /// Feeds frames at `fps` for recording times `start..<end` and, interleaved in time order, sine
    /// buffers for each audio track. With `audioPastEnd` the last audio buffer may cross `end` (it
    /// straddles a following pause). `audioDriftPPM` makes the audio host timestamps run that much faster
    /// (positive) or slower than the sample count, like a drifting device clock. No audio is delivered
    /// for host times in `audioStall` (a stalled source). Paced so the real-time
    /// inputs keep up.
    static func record(
        _ writer: VideoFileWriter, from start: Double, to end: Double, fps: Int,
        audio tracks: [AudioTrackKind] = [], audioFormat sine: SineFormat = .stereo48k,
        audioPastEnd: Bool = false, audioDriftPPM: Double = 0, audioStall: Range<Double>? = nil,
        frameDelay: Duration = .milliseconds(8),
        frame: (Double) -> CVPixelBuffer
    ) async {
        let rate = Double(sine.sampleRate)
        let drift = 1 + audioDriftPPM / 1_000_000
        let bufferSeconds = Double(audioFrames) / rate * drift
        func host(_ sample: Int64) -> Double { Double(sample) / rate * drift }
        let epsilon = 1e-9
        let frameCount = Int(((end - start) * Double(fps)).rounded())
        var nextSample = Int64((start * rate / drift).rounded())
        for i in 0..<frameCount {
            let t = start + Double(i) / Double(fps)
            writer.appendVideo(frame(t), hostTime: hostTime(t))
            while !tracks.isEmpty, host(nextSample) < t + 1 / Double(fps) - epsilon,
                  audioPastEnd ? host(nextSample) < end - epsilon : host(nextSample) + bufferSeconds <= end + epsilon {
                let pts = audioDriftPPM == 0 ? nil : hostTime(host(nextSample))
                let stalled = audioStall?.contains(host(nextSample)) ?? false
                for track in tracks where !stalled {
                    writer.appendAudio(sineBuffer(startSample: nextSample, format: sine, pts: pts), track: track)
                }
                nextSample += Int64(audioFrames)
            }
            // Frames come about four times faster than real time (faster pacing made the CI VM's software
            // encoder drop frames at random); give the encoder time to spin up first.
            try? await Task.sleep(for: i == 0 ? .milliseconds(200) : frameDelay)
        }
    }

    static func solidRecording(width: Int, height: Int) -> (Double) -> CVPixelBuffer {
        { t in solidFrame(width: width, height: height, colorIndex: colorIndex(at: t)) }
    }
}
