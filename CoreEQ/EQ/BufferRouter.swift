import CoreAudio
import Foundation

/// Moves the tap's channels into the device's output channels.
///
/// The other half of `OutputPlan`, which works out on the main thread *where*
/// each tap channel should go; this carries that out on the render thread. They
/// are separate because one may read device properties and take its time, and
/// the other may do neither.
///
/// Nothing here reasons about audio. It reasons about buffer lists: which
/// buffer holds a channel, where in it that channel starts, and how far apart
/// its samples are. That is the whole job, and it is worth its own type because
/// getting it wrong is silent — a channel written to the wrong place, or four
/// frames of stereo smeared across one frame of eight, sounds like a broken
/// device rather than like a bug.
///
/// A struct, stored inline by the processor: this is touched once per channel
/// per block on the audio thread, where a class would add a retain and an
/// indirection for nothing.
struct BufferRouter {

    /// Where one channel lives in a buffer list.
    struct Span {
        var pointer: UnsafeMutablePointer<Float>
        /// Distance between consecutive samples of this channel, in samples.
        /// One for a mono buffer, the channel count for an interleaved one.
        var stride: Int
        var frames: Int
    }

    /// Tap channels the render path carries, which is what the layout named
    /// capped by what the processor can hold.
    private(set) var routedChannels = 2

    /// Global output channel each tap channel is written to. -1 means dropped.
    private(set) var destinations = Array(0..<EQProcessor.maxChannels)

    /// Input buffer and channel each tap channel is read from.
    private(set) var sourceBuffers = [Int](repeating: 0, count: EQProcessor.maxChannels)
    private(set) var sourceChannels = Array(0..<EQProcessor.maxChannels)

    /// Which input buffer the primary tap was described as occupying, and how
    /// wide it is. Both are used to recognise it if the description turns out
    /// not to fit the device.
    private(set) var tapBufferIndex = 0
    private(set) var tapChannelCount = 2

    // MARK: - Configuration (render thread, from staged values)

    mutating func setRouting(
        channels: Int, destinations newDestinations: [Int], sourceBuffers newBuffers: [Int],
        sourceChannels newChannels: [Int]
    ) {
        routedChannels = channels
        for channel in 0..<channels {
            destinations[channel] = newDestinations[channel]
            sourceBuffers[channel] = newBuffers[channel]
            sourceChannels[channel] = newChannels[channel]
        }
    }

    mutating func setTapBuffer(_ index: Int) { tapBufferIndex = index }
    mutating func setTapChannelCount(_ count: Int) { tapChannelCount = count }

    /// Whether a proposed routing differs from the one in force, which is what
    /// decides if the delay lines are describing audio that is no longer there.
    func differs(
        channels: Int, destinations other: [Int], sourceBuffers otherBuffers: [Int],
        sourceChannels otherChannels: [Int]
    ) -> Bool {
        guard channels == routedChannels else { return true }
        for channel in 0..<channels
        where other[channel] != destinations[channel]
            || otherBuffers[channel] != sourceBuffers[channel]
            || otherChannels[channel] != sourceChannels[channel]
        {
            return true
        }
        return false
    }

    // MARK: - Placing audio (render thread)

    /// Copies each routed channel from the input channel the layout names to the
    /// output channel it names, and returns how many frames were written.
    ///
    /// Source and destination are both explicit. With one tap every source is
    /// the same buffer and the channels are read in order; with one tap per
    /// output stream they are not, and nothing here needs to know which case it
    /// is in.
    /// What one pass of `place` moved.
    struct Placement {
        var frames = 0
        /// Loudest source sample copied, which is what the chain was handed.
        ///
        /// Taken here because this is the only place that touches exactly the
        /// samples which become CoreEQ's output — not the whole input list,
        /// which on a duplex device also carries the device's own input, and a
        /// live microphone in it would read as a loud source.
        var sourcePeak: Float = 0
    }

    func place(
        _ inABL: UnsafeMutableAudioBufferListPointer,
        into outABL: UnsafeMutableAudioBufferListPointer,
        substitute: Int?
    ) -> Placement {
        var placement = Placement()
        for channel in 0..<routedChannels {
            guard let source = origin(of: channel, in: inABL, substitute: substitute),
                let target = destination(of: destinations[channel], in: outABL)
            else { continue }
            let count = min(source.frames, target.frames)
            var read = source.pointer
            var sink = target.pointer
            for _ in 0..<count {
                let sample = read.pointee
                sink.pointee = sample
                let magnitude = abs(sample)
                if magnitude > placement.sourcePeak { placement.sourcePeak = magnitude }
                read += source.stride
                sink += target.stride
            }
            placement.frames = max(placement.frames, count)
        }
        return placement
    }

    /// Where routed channel `index` ended up in the output list, or nil when the
    /// device has no such channel.
    func output(
        of index: Int, in outABL: UnsafeMutableAudioBufferListPointer
    ) -> Span? {
        guard index >= 0, index < routedChannels else { return nil }
        return destination(of: destinations[index], in: outABL)
    }

    /// Locates one routed channel in the input list: which buffer it is in,
    /// where it starts, and how far apart its samples are. The mirror of
    /// `destination`, and nil on the same terms — a channel the input does not
    /// have is left silent rather than read from nowhere.
    private func origin(
        of channel: Int, in inABL: UnsafeMutableAudioBufferListPointer, substitute: Int?
    ) -> (pointer: UnsafePointer<Float>, stride: Int, frames: Int)? {
        var buffer = sourceBuffers[channel]
        // The described buffer was not the tap, so the one the search found
        // stands in for it — the old behaviour, kept for the taps it applies to.
        if let substitute, buffer == tapBufferIndex { buffer = substitute }
        guard buffer >= 0, buffer < inABL.count,
            let data = inABL[buffer].mData?.assumingMemoryBound(to: Float.self)
        else { return nil }
        let channels = Int(inABL[buffer].mNumberChannels)
        let source = sourceChannels[channel]
        guard channels > 0, source >= 0, source < channels else { return nil }
        let frames = Int(inABL[buffer].mDataByteSize) / (MemoryLayout<Float>.size * channels)
        return (UnsafePointer(data + source), channels, frames)
    }

    /// Locates one global output channel: which buffer holds it, where in that
    /// buffer it starts, and how far apart its samples are.
    ///
    /// Returns nil when the layout names a channel the device does not have,
    /// which is the honest answer — better a silent channel than a write past
    /// the end of a buffer.
    private func destination(
        of globalChannel: Int, in outABL: UnsafeMutableAudioBufferListPointer
    ) -> Span? {
        guard globalChannel >= 0 else { return nil }
        var base = 0
        for i in 0..<outABL.count {
            let buffer = outABL[i]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            if globalChannel < base + channels {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    return nil
                }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return Span(
                    pointer: data + (globalChannel - base), stride: channels, frames: frames)
            }
            base += channels
        }
        return nil
    }

    /// The buffer to read instead of the one the layout named, or nil when the
    /// named one is right.
    ///
    /// Position is taken from the layout rather than searched for: the aggregate
    /// lists its sub-device's input buffers before the taps', so it is known on
    /// the main thread, where device properties may be read — see
    /// `OutputPlan.tapBufferIndex`.
    ///
    /// Searching by channel count was wrong, and wrong in the quietest possible
    /// way. A duplex output device presents an input stream of its own, and when
    /// that stream is as wide as the tap it matches first: on BlackHole 16ch —
    /// sixteen in, sixteen out — CoreEQ equalized the device's own silent input
    /// and wrote silence to the speakers, while the tap went on muting every
    /// other process. The engine reported `running` throughout.
    ///
    /// The search survives as the fallback. A description that does not fit the
    /// device is a reason to look, not a reason to drop every block.
    func substituteTapBuffer(in inABL: UnsafeMutableAudioBufferListPointer) -> Int? {
        if tapBufferIndex >= 0, tapBufferIndex < inABL.count,
            inABL[tapBufferIndex].mData != nil,
            inABL[tapBufferIndex].mNumberChannels == UInt32(tapChannelCount)
        {
            return nil
        }
        for i in 0..<inABL.count
        where inABL[i].mNumberChannels == UInt32(tapChannelCount) && inABL[i].mData != nil {
            return i
        }
        for i in 0..<inABL.count
        where inABL[i].mNumberChannels == UInt32(routedChannels) && inABL[i].mData != nil {
            return i
        }
        for i in 0..<inABL.count where inABL[i].mData != nil {
            return i
        }
        return nil
    }
}
