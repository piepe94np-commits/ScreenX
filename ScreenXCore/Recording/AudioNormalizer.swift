import AVFoundation
import CoreMedia

/// Converts one track's incoming audio (any linear PCM format, possibly changing mid-stream, e.g. after
/// a microphone switch) to interleaved float32 48 kHz stereo. Confined to the writer queue.
///
/// Timing: output runs continuously by sample count, so the audio has no steps while the device clock
/// and the host clock agree. When they drift apart by more than `resyncThreshold` (20–200 ppm of device
/// drift reaches that after minutes), after a drop, or across a pause gap, the output restarts at the
/// buffer's host-derived time. A forward jump of any length (a stall of the source) is filled with
/// silence in chunks of at most 1 s, so the encoder always sees contiguous audio; a backward one trims the converted buffer's leading frames so no output starts
/// before the previous output end (a buffer that is fully covered is dropped). The sync error therefore
/// stays below 20 ms, with one short step per correction.
final class AudioNormalizer {
    /// Silent frames that fill a forward gap, emitted in chunks of at most 1 s.
    struct Silence {
        let start: CMTime
        let frames: Int

        struct Chunk {
            let start: CMTime
            let frames: Int
            var end: CMTime { CMTimeAdd(start, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(VideoWriterSettings.audioSampleRate))) }
        }

        func chunks() -> [Chunk] {
            stride(from: 0, to: frames, by: VideoWriterSettings.audioSampleRate).map { offset in
                Chunk(start: CMTimeAdd(start, CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(VideoWriterSettings.audioSampleRate))),
                      frames: min(VideoWriterSettings.audioSampleRate, frames - offset))
            }
        }
    }

    enum Result {
        /// Converted audio starting at `start`, preceded by `silence` if there was a gap before it.
        case output(silence: Silence?, buffer: CMSampleBuffer, start: CMTime)
        /// The converter produced no frames yet (not a drop).
        case empty
        /// Fully covered by earlier output; dropped.
        case covered
        case failed
    }

    private let outputFormat = VideoWriterSettings.normalizedAudioFormat()
    private var converter: AVAudioConverter?
    private var inputDescription: CMFormatDescription?
    private var inputFormat: AVAudioFormat?
    /// Output time at which the next converted frames continue.
    private var nextTime: CMTime?
    /// End of the last emitted output; nothing may start before it.
    private var outputEnd: CMTime?
    private var needsResync = false
    private static let resyncThreshold = CMTime(value: 20, timescale: 1000)
    /// Timing corrections so far (for tests and diagnostics).
    private(set) var resyncs = 0
    private(set) var silenceFrames = 0
    private(set) var trimmedFrames = 0

    /// A buffer of this track was dropped: restart timing at the next buffer. If an output was only
    /// partly appended, `writtenEnd` is where the written audio really ends.
    func noteDrop(writtenEnd: CMTime? = nil) {
        needsResync = true
        if let writtenEnd { outputEnd = writtenEnd }
    }

    /// Converts `sampleBuffer`, whose start maps to output time `time`.
    func convert(_ sampleBuffer: CMSampleBuffer, at time: CMTime) -> Result {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return .failed }
        if inputDescription.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: description) }) ?? true {
            guard let format = Self.audioFormat(of: description),
                  let converter = AVAudioConverter(from: format, to: outputFormat) else {
                return .failed
            }
            converter.primeMethod = .none
            converter.downmix = format.channelCount > outputFormat.channelCount
            self.converter = converter
            // `nextTime` is kept, so output stays continuous across a format change.
            inputFormat = format
            inputDescription = description
        }
        guard let converter, let inputFormat else { return .failed }
        if needsResync || nextTime.map({
            CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(time, $0)), Self.resyncThreshold) > 0
        }) ?? true {
            if nextTime != nil { resyncs += 1 }
            converter.reset()
            nextTime = time
            needsResync = false
        }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else {
            return .failed
        }
        guard Self.copyPCM(from: sampleBuffer, into: input) else { return .failed }
        input.frameLength = frames

        let capacity = AVAudioFrameCount(
            (Double(frames) * outputFormat.sampleRate / inputFormat.sampleRate).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return .failed
        }
        let pending = PendingInput(buffer: input)
        var error: NSError?
        // Mid-stream the block answers `.noDataNow`, never `.endOfStream`: that would end the converter's
        // stream. Flushing the resampler's tail at the very end is not needed.
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let buffer = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return .failed }
        guard output.frameLength > 0, var start = nextTime else { return .empty }

        let rate = CMTimeScale(outputFormat.sampleRate)
        let produced = CMTime(value: CMTimeValue(output.frameLength), timescale: rate)
        var skip: AVAudioFrameCount = 0
        var silence: Silence?
        if let outputEnd, CMTimeCompare(start, outputEnd) > 0 {
            // Fill a forward jump of any length with silence so the encoder sees contiguous audio;
            // AVAssetWriter would otherwise close the timestamp gap and shift everything after it earlier.
            let frames = Int((CMTimeSubtract(start, outputEnd).seconds * outputFormat.sampleRate).rounded())
            if frames > 0 {
                silence = Silence(start: outputEnd, frames: frames)
                start = CMTimeAdd(outputEnd, CMTime(value: CMTimeValue(frames), timescale: rate))
                silenceFrames += frames
            }
        } else if let outputEnd, CMTimeCompare(start, outputEnd) < 0 {
            let overlap = CMTimeSubtract(outputEnd, start).seconds * outputFormat.sampleRate
            guard overlap < Double(output.frameLength) else {
                nextTime = CMTimeAdd(start, produced)
                return .covered
            }
            skip = AVAudioFrameCount(overlap.rounded(.up))
            start = outputEnd
            trimmedFrames += Int(skip)
        }
        let end = CMTimeAdd(start, CMTime(value: CMTimeValue(output.frameLength - skip), timescale: rate))
        guard let result = Self.sampleBuffer(from: output, skipping: skip, at: start) else { return .failed }
        nextTime = end
        outputEnd = end
        return .output(silence: silence, buffer: result, start: start)
    }

    /// A ready buffer of silent output frames for one chunk of a gap.
    func silenceBuffer(_ chunk: Silence.Chunk) -> CMSampleBuffer? {
        let byteCount = chunk.frames * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                       dataLength: byteCount) == noErr
        else { return nil }
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: outputFormat.formatDescription,
            sampleCount: chunk.frames, presentationTimeStamp: chunk.start, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer) == noErr
        else { return nil }
        return sampleBuffer
    }

    /// The input format; buffers with more than two channels and no layout get a discrete layout.
    private static func audioFormat(of description: CMAudioFormatDescription) -> AVAudioFormat? {
        guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = basic.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        var layoutSize = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize),
           layoutSize > 0 {
            return AVAudioFormat(streamDescription: &asbd, channelLayout: AVAudioChannelLayout(layout: layout))
        }
        if asbd.mChannelsPerFrame <= 2 {
            return AVAudioFormat(streamDescription: &asbd)
        }
        guard let discrete = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame) else { return nil }
        return AVAudioFormat(streamDescription: &asbd, channelLayout: discrete)
    }

    /// Copies the sample buffer's PCM data (interleaved or one plane per channel) into `buffer`.
    private static func copyPCM(from sampleBuffer: CMSampleBuffer, into buffer: AVAudioPCMBuffer) -> Bool {
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
            listSize > 0
        else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer) == noErr
        else { return false }
        let source = UnsafeMutableAudioBufferListPointer(listPointer)
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard source.count == destination.count else { return false }
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { return false }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return withExtendedLifetime(blockBuffer) { true }
    }

    /// Wraps interleaved PCM, without its first `skip` frames, in a ready `CMSampleBuffer` starting at `time`.
    private static func sampleBuffer(from buffer: AVAudioPCMBuffer, skipping skip: AVAudioFrameCount,
                                     at time: CMTime) -> CMSampleBuffer? {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard list.count == 1, let base = list[0].mData, skip < buffer.frameLength else { return nil }
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let data = base + Int(skip) * bytesPerFrame
        let frameCount = buffer.frameLength - skip
        let byteCount = Int(frameCount) * bytesPerFrame
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            CMBlockBufferReplaceDataBytes(
                with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) == noErr
        else { return nil }
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(frameCount), presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr
        else { return nil }
        return sampleBuffer
    }
}

/// Hands one input buffer to `AVAudioConverter`'s input block, which the converter calls synchronously
/// inside `convert`. `@unchecked Sendable` because it never leaves that call.
private final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
