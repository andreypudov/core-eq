import CoreAudio
import Foundation
import os

/// Realtime-safe equalizer: one flat chain of biquads.
///
/// The processor has no notion of bands, sliders, or lists — it receives the
/// whole chain as an array and runs every entry the same way. That is what
/// makes CoreEQ's two editing surfaces two views of one equalizer rather than
/// two equalizers.
///
/// The render path (`render(input:output:)`) runs on the Core Audio IO thread
/// and never blocks: parameter changes from the main thread are staged behind
/// an unfair lock and picked up with `lockIfAvailable()`; if the lock is
/// contended the previous parameters are simply reused for one more cycle.
/// Gain changes are smoothed over ~50 ms so profile switches are glitch-free.
///
/// Filters are RBJ audio-cookbook biquads, processed in transposed direct form
/// II with per-filter, per-channel state.
///
/// `@unchecked Sendable` because that split is the whole design: every mutable
/// field is either written only from the main thread and read only behind the
/// staging lock, or touched only by the render thread. The compiler cannot see
/// a rule enforced by an unfair lock and a documented thread contract, so this
/// asserts it — and it has to be asserted, because the IO block that calls
/// `render` must not inherit the main-actor isolation of the engine that
/// creates it.
final class EQProcessor: @unchecked Sendable {
    /// Eleven ladder slots plus `BuiltInProfiles.maxFreeFilters`, with room left
    /// for automatically generated processing later. Each filter is one more
    /// pass over the buffer in `processChannel`, so this is a real budget.
    static let maxFilters = 32
    /// Channels the render path can carry. Two was not a budget but an
    /// assumption — the delay lines were named `z1L`/`z1R`.
    ///
    /// Sixteen covered 7.1.4 and every layout a Mac *presents by itself*, but
    /// not the devices people attach to one: BlackHole ships a 64 channel
    /// build, and Dante and MADI interfaces are routinely wider than sixteen.
    /// The cost is `maxFilters × maxChannels × 2` doubles of delay line,
    /// allocated once — 8 KB at sixteen, 32 KB at sixty-four — and the
    /// per-sample work is set by the channels actually routed, not by this
    /// ceiling. Twenty-four kilobytes is not worth losing three quarters of a
    /// device over.
    static let maxChannels = 64

    private static let smoothingSeconds = 0.05

    /// Mono copy of the played-back output, tapped for the spectrum analyzer.
    /// 8192 samples is well beyond the analyzer's 4096-sample window, so the
    /// consumer can snapshot without the producer overtaking the read region.
    let spectrumBuffer = SpectrumAudioBuffer(capacity: 8_192)

    /// Where the tap's channels land in the device's output layout.
    ///
    /// `render` used to assume two things that are only true of a plain stereo
    /// device: that input buffer *i* pairs with output buffer *i*, and that both
    /// hold the same channels. Neither survives a device presenting more than
    /// two channels, or an aggregate presenting one buffer per sub-device. This
    /// is those assumptions made explicit and worked out once, on the main
    /// thread, where reading device properties is allowed.
    ///
    /// Channels are numbered globally: buffers are walked in order and their
    /// channel counts accumulated, so channel *g* is found by walking until a
    /// buffer contains it. That one numbering covers interleaved stereo, a wide
    /// interleaved buffer, one buffer per sub-device, and fully non-interleaved
    /// layouts without a special case for any of them.
    struct OutputLayout: Equatable {
        /// Channels the tap delivers.
        var tapChannels: Int
        /// Global output channel for each tap channel, in tap channel order. An
        /// entry of -1 drops that channel, and the array may be shorter than
        /// `tapChannels`, which drops the rest.
        ///
        /// Held as an array because only the main thread ever touches this type;
        /// `setOutputLayout` copies it into storage the render thread already
        /// owns, the same way a filter chain is staged.
        var destinations: [Int]
        /// Which buffer of the input list carries the tap. The aggregate lists
        /// its sub-device's input buffers first, so this is nonzero whenever the
        /// output device is duplex.
        ///
        /// With several taps this is the *first* of them, and the one the
        /// fallback search stands in for; `sourceBuffers` is what the render
        /// path actually reads.
        var tapBufferIndex: Int
        /// Input buffer each routed channel is read from, in routed order.
        var sourceBuffers: [Int]
        /// Channel within that buffer, in routed order.
        var sourceChannels: [Int]
        /// Channels the buffer at `tapBufferIndex` should hold. With one tap
        /// that is the tap's whole width; with several it is the first tap's.
        /// Used only to recognise the buffer, never to route.
        var primaryTapChannels: Int

        /// Channels the render path will actually carry.
        ///
        /// A tap wider than `maxChannels` is routed as far as the delay lines
        /// reach and the rest is dropped. Derived here rather than recomputed by
        /// callers, so the cap is stated in one place.
        var routedChannels: Int { min(tapChannels, EQProcessor.maxChannels) }

        /// One tap, whose channels are read in order — every device CoreEQ has
        /// ever seen presents its output as a single stream, and this is that
        /// case written down.
        init(tapChannels: Int = 2, destinations: [Int] = [0, 1], tapBufferIndex: Int = 0) {
            self.tapChannels = tapChannels
            self.destinations = destinations
            self.tapBufferIndex = tapBufferIndex
            self.sourceBuffers = [Int](repeating: tapBufferIndex, count: max(0, tapChannels))
            self.sourceChannels = Array(0..<max(0, tapChannels))
            self.primaryTapChannels = tapChannels
        }

        /// Several taps, one per output stream. A tap binds to exactly one
        /// stream — `CATapDescription` offers no way to bind to a whole device —
        /// so a device presenting its channels as several streams needs one tap
        /// each, and each tap's channels have to be told where they belong.
        init(
            tapChannels: Int, destinations: [Int], tapBufferIndex: Int,
            sourceBuffers: [Int], sourceChannels: [Int], primaryTapChannels: Int
        ) {
            self.tapChannels = tapChannels
            self.destinations = destinations
            self.tapBufferIndex = tapBufferIndex
            self.sourceBuffers = sourceBuffers
            self.sourceChannels = sourceChannels
            self.primaryTapChannels = primaryTapChannels
        }
    }

    /// What the render thread needs to know about one filter: no identifier, no
    /// colour, no ladder slot. Plain data, so staging a chain is a fixed number
    /// of scalar copies into storage that already exists.
    private struct FilterParameters: Equatable {
        var kind = EQFilter.Kind.bell
        var frequency = 1_000.0
        var gain = 0.0
        var q = 1.0
        var isEnabled = true

        init() {}

        init(_ filter: EQFilter) {
            kind = filter.kind
            frequency = filter.frequency
            gain = filter.gain
            q = filter.q
            isEnabled = filter.isEnabled
        }

        /// Whether a change here invalidates the coefficients and the filter's
        /// delay line. Gain is excluded: it is ramped rather than jumped, so it
        /// updates coefficients without discarding state.
        func changesShape(from other: FilterParameters) -> Bool {
            kind != other.kind
                || frequency != other.frequency
                || q != other.q
                || isEnabled != other.isEnabled
        }
    }

    private struct FilterState {
        var parameters = FilterParameters()
        var targetGain = 0.0
        var currentGain = 0.0
        var needsCoefficientUpdate = true
        var filter = Biquad.identity
    }

    // Staged parameters, written by the main thread under `lock` and consumed
    // by the render thread.
    //
    // The staging chain is allocated once, at its maximum length, and written
    // in place. Handing over a fresh `[EQFilter]` instead would make the render
    // thread the last owner of that array — and therefore the thread that frees
    // it, inside the IO callback, on every parameter change. A slider drag
    // sends one array per frame, so that is a `free()` on the audio thread sixty
    // times a second: unbounded in principle, and exactly the kind of thing that
    // shows up as a dropout under memory pressure rather than in testing.
    private let lock = OSAllocatedUnfairLock()
    private var pendingFilters = [FilterParameters](
        repeating: FilterParameters(), count: EQProcessor.maxFilters)
    /// Number of staged filters, or nil when no chain is waiting to be picked up.
    private var pendingFilterCount: Int?
    private var pendingPreamp: Double?
    private var pendingBypass: Bool?
    private var pendingSampleRate: Double?
    /// Staged destination map and its length, written under the lock into
    /// storage that already exists so no array is handed to the render thread.
    private var pendingDestinations = [Int](repeating: -1, count: EQProcessor.maxChannels)
    private var pendingRoutedChannels: Int?
    private var pendingTapBufferIndex: Int?
    private var pendingTapChannelCount: Int?
    private var pendingSourceBuffers = [Int](repeating: 0, count: EQProcessor.maxChannels)
    private var pendingSourceChannels = Array(0..<EQProcessor.maxChannels)

    // Render-thread-only state.
    private var filters = [FilterState](repeating: FilterState(), count: EQProcessor.maxFilters)
    private var filterCount = 0
    /// Where a staged chain is copied to while the lock is held, so the lock is
    /// released before the longer work of comparing it against what is running.
    /// Holding it across that would put the main thread in a position to block
    /// on the audio thread, which is the inversion the staging exists to avoid.
    private var stagedFilters = [FilterParameters](
        repeating: FilterParameters(), count: EQProcessor.maxFilters)
    private var stagedDestinations = [Int](repeating: -1, count: EQProcessor.maxChannels)
    private var stagedSourceBuffers = [Int](repeating: 0, count: EQProcessor.maxChannels)
    private var stagedSourceChannels = Array(0..<EQProcessor.maxChannels)
    private var sampleRate = 44_100.0
    private var bypassed = false
    /// Delay lines for every filter and channel, flat and allocated once:
    /// filter-major, then channel, then the two states. Two per filter per
    /// channel is what transposed direct form II needs.
    private var delays = [Double](
        repeating: 0, count: EQProcessor.maxFilters * EQProcessor.maxChannels * 2)
    /// Where each tap channel is written, render-thread owned. -1 is "nowhere".
    /// Defaults to the identity map, so a processor the engine has not described
    /// yet behaves as plain interleaved audio rather than as silence.
    private var destinations = Array(0..<EQProcessor.maxChannels)
    /// Tap channels currently routed, never more than `destinations` holds.
    private var routedChannels = 2
    /// Input buffer the tap arrives in, render-thread owned. Zero is correct for
    /// an output-only device, which presents no input buffers of its own.
    private var tapBufferIndex = 0
    /// Channels the tap delivers, *unclamped* — `routedChannels` is capped at
    /// `maxChannels`, and recognising the tap needs its real width.
    private var tapChannelCount = 2
    /// Input buffer each routed channel is read from, render-thread owned.
    private var sourceBuffers = [Int](repeating: 0, count: EQProcessor.maxChannels)
    /// Channel within that buffer, render-thread owned.
    private var sourceChannels = Array(0..<EQProcessor.maxChannels)
    // Output trim, smoothed like the band gains so dragging the preamp slider
    // is a fade rather than a step.
    private var targetPreampLinear = 1.0
    private var currentPreampLinear = 1.0

    // MARK: - Control (any thread)

    /// Stages a chain for the render thread. Anything past `maxFilters` is
    /// dropped here rather than in the callback, so the render side never has to
    /// reason about a chain longer than its storage.
    func setFilters(_ newFilters: [EQFilter]) {
        let count = min(newFilters.count, Self.maxFilters)
        lock.lock()
        for i in 0..<count {
            pendingFilters[i] = FilterParameters(newFilters[i])
        }
        pendingFilterCount = count
        lock.unlock()
    }

    func setPreamp(_ dB: Double) {
        lock.lock()
        pendingPreamp = dB
        lock.unlock()
    }

    func setBypassed(_ value: Bool) {
        lock.lock()
        pendingBypass = value
        lock.unlock()
    }

    /// Stages the output layout. Set by `AudioEngine` once per engine start,
    /// after it knows the aggregate's stream configuration and the tap's format.
    func setOutputLayout(_ newLayout: OutputLayout) {
        let count = min(newLayout.tapChannels, Self.maxChannels)
        lock.lock()
        for channel in 0..<count {
            pendingDestinations[channel] = newLayout.destinations[safe: channel] ?? -1
            pendingSourceBuffers[channel] =
                newLayout.sourceBuffers[safe: channel] ?? newLayout.tapBufferIndex
            pendingSourceChannels[channel] = newLayout.sourceChannels[safe: channel] ?? channel
        }
        pendingRoutedChannels = count
        pendingTapBufferIndex = max(0, newLayout.tapBufferIndex)
        pendingTapChannelCount = max(0, newLayout.primaryTapChannels)
        lock.unlock()
    }

    func setSampleRate(_ rate: Double) {
        guard rate > 0 else { return }
        lock.lock()
        pendingSampleRate = rate
        lock.unlock()
    }

    // MARK: - Render (Core Audio IO thread)

    /// Places tapped system audio into `output` at the positions `layout` names,
    /// applying the EQ unless bypassed. Assumes Float32 samples, the native
    /// format for process taps and aggregate device IO.
    ///
    /// Nothing here reasons about buffer *positions*. The tap is found in the
    /// input list by its format, and its channels are written to the global
    /// output channels the layout names — so a stereo tap feeding an eight
    /// channel device fills two channels and silences six, rather than smearing
    /// four frames of stereo across one frame of eight.
    func render(
        input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outABL = UnsafeMutableAudioBufferListPointer(output)

        consumePendingParameters()

        // Silence first, then place. Every output channel the tap does not feed
        // has to end up silent rather than left as it was found, and so does the
        // tail of a buffer longer than the tap delivered. Clearing up front makes
        // both of those one memset instead of a special case each.
        for i in 0..<outABL.count {
            guard let data = outABL[i].mData else { continue }
            memset(data, 0, Int(outABL[i].mDataByteSize))
        }

        // Where the primary tap actually turned up, which may not be where it
        // was described. Resolved once per block rather than per channel.
        let substitute = substituteTapBuffer(in: inABL)
        let placed = place(inABL, into: outABL, substitute: substitute)

        if !bypassed, placed > 0 {
            advanceSmoothing(frames: placed)
            equalize(outABL, frames: placed)
        }

        feedSpectrum(outABL)
    }

    /// Copies each routed channel from the input channel the layout names to the
    /// output channel it names, and returns how many frames were written.
    ///
    /// Source and destination are both explicit. With one tap every source is
    /// the same buffer and the channels are read in order; with one tap per
    /// output stream they are not, and nothing here needs to know which case it
    /// is in.
    private func place(
        _ inABL: UnsafeMutableAudioBufferListPointer,
        into outABL: UnsafeMutableAudioBufferListPointer,
        substitute: Int?
    ) -> Int {
        var written = 0
        for channel in 0..<routedChannels {
            guard let source = origin(of: channel, in: inABL, substitute: substitute),
                let target = destination(of: destinations[channel], in: outABL)
            else { continue }
            let count = min(source.frames, target.frames)
            var read = source.pointer
            var sink = target.pointer
            for _ in 0..<count {
                sink.pointee = read.pointee
                read += source.stride
                sink += target.stride
            }
            written = max(written, count)
        }
        return written
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

    /// Runs the chain and the output trim over the channels the tap was placed
    /// into. The rest of the device's channels are silence and stay that way.
    private func equalize(
        _ outABL: UnsafeMutableAudioBufferListPointer, frames: Int
    ) {
        for channel in 0..<routedChannels {
            guard let target = destination(of: destinations[channel], in: outABL)
            else { continue }
            let count = min(frames, target.frames)
            processChannel(
                target.pointer, stride: target.stride, frames: count, channel: channel)
            applyPreamp(target.pointer, stride: target.stride, frames: count)
        }
    }

    /// Locates one global output channel: which buffer holds it, where in that
    /// buffer it starts, and how far apart its samples are.
    ///
    /// Returns nil when the layout names a channel the device does not have,
    /// which is the honest answer — better a silent channel than a write past
    /// the end of a buffer.
    private func destination(
        of globalChannel: Int, in outABL: UnsafeMutableAudioBufferListPointer
    ) -> (pointer: UnsafeMutablePointer<Float>, stride: Int, frames: Int)? {
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
                return (data + (globalChannel - base), channels, frames)
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
    private func substituteTapBuffer(in inABL: UnsafeMutableAudioBufferListPointer) -> Int? {
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

    /// Hands a mono copy of the final output — equalized when enabled, the
    /// untouched passthrough when bypassed — to the spectrum buffer, so the
    /// analyzer always shows what is actually reaching the speakers.
    ///
    /// Reads the channels the audio was placed into rather than the head of the
    /// first buffer, which on a multichannel device is not where the audio is.
    private func feedSpectrum(_ outABL: UnsafeMutableAudioBufferListPointer) {
        guard routedChannels > 0,
            let left = destination(of: destinations[0], in: outABL), left.frames > 0
        else { return }
        // Average the pair when the map put it side by side in one buffer, which
        // is every interleaved device. Otherwise the first channel alone is an
        // honest enough picture for a backdrop.
        let right = routedChannels > 1 ? destination(of: destinations[1], in: outABL) : nil
        let adjacent = right.map { $0.pointer == left.pointer + 1 && $0.stride == left.stride }
        spectrumBuffer.write(
            interleaved: left.pointer,
            frames: left.frames,
            channels: adjacent == true ? 2 : 1,
            stride: left.stride
        )
    }

    // MARK: - Render-thread helpers

    /// First of the two delay-line slots for one filter on one channel.
    private func delayIndex(filter: Int, channel: Int) -> Int {
        (filter * Self.maxChannels + channel) * 2
    }

    /// Clears one filter's delay lines across every channel. Called when a
    /// filter's shape changes, because the state describes the old response.
    private func resetDelays(filter: Int) {
        let base = filter * Self.maxChannels * 2
        for offset in 0..<(Self.maxChannels * 2) {
            delays[base + offset] = 0
        }
    }

    private func resetAllDelays() {
        for i in 0..<delays.count { delays[i] = 0 }
    }

    private func consumePendingParameters() {
        guard lock.lockIfAvailable() else { return }
        // Copied out under the lock into fixed storage the render thread already
        // owns, so nothing is allocated, retained, or released here.
        let newFilterCount = pendingFilterCount
        if let newFilterCount {
            for i in 0..<newFilterCount {
                stagedFilters[i] = pendingFilters[i]
            }
        }
        let newPreamp = pendingPreamp
        let newBypass = pendingBypass
        let newRate = pendingSampleRate
        let newRouted = pendingRoutedChannels
        let newTapBuffer = pendingTapBufferIndex
        let newTapChannels = pendingTapChannelCount
        if let newRouted {
            for channel in 0..<newRouted {
                stagedDestinations[channel] = pendingDestinations[channel]
                stagedSourceBuffers[channel] = pendingSourceBuffers[channel]
                stagedSourceChannels[channel] = pendingSourceChannels[channel]
            }
        }
        pendingFilterCount = nil
        pendingPreamp = nil
        pendingBypass = nil
        pendingSampleRate = nil
        pendingRoutedChannels = nil
        pendingTapBufferIndex = nil
        pendingTapChannelCount = nil
        lock.unlock()

        if let newTapChannels { tapChannelCount = newTapChannels }

        if let newTapBuffer, newTapBuffer != tapBufferIndex {
            tapBufferIndex = newTapBuffer
            // A different input buffer is different audio, so the delay lines
            // are describing something that is no longer arriving.
            resetAllDelays()
        }

        if let newRouted {
            var changed = newRouted != routedChannels
            for channel in 0..<newRouted
            where stagedDestinations[channel] != destinations[channel]
                || stagedSourceBuffers[channel] != sourceBuffers[channel]
                || stagedSourceChannels[channel] != sourceChannels[channel]
            {
                changed = true
            }
            if changed {
                routedChannels = newRouted
                for channel in 0..<newRouted {
                    destinations[channel] = stagedDestinations[channel]
                    sourceBuffers[channel] = stagedSourceBuffers[channel]
                    sourceChannels[channel] = stagedSourceChannels[channel]
                }
                // Different channels means the delay lines are describing audio
                // that is no longer there.
                resetAllDelays()
            }
        }

        if let newRate, newRate != sampleRate {
            sampleRate = newRate
            for i in 0..<filterCount {
                filters[i].needsCoefficientUpdate = true
                resetDelays(filter: i)
            }
        }

        if let newFilterCount {
            filterCount = newFilterCount
            for i in 0..<filterCount {
                let staged = stagedFilters[i]
                if staged.changesShape(from: filters[i].parameters) {
                    filters[i].needsCoefficientUpdate = true
                    resetDelays(filter: i)
                }
                filters[i].parameters = staged
                // Switching a gain-bearing filter off ramps it to zero, which is
                // the same smooth path a slider drag takes and lands on identity.
                // High and low pass have no gain to ramp, so they switch at once.
                filters[i].targetGain = staged.isEnabled ? staged.gain : 0
            }
        }

        if let newPreamp {
            targetPreampLinear = pow(10.0, newPreamp / 20.0)
        }

        if let newBypass, newBypass != bypassed {
            bypassed = newBypass
            if !bypassed {
                for i in 0..<filterCount { resetDelays(filter: i) }
            }
        }
    }

    /// Output trim, applied after every filter — this is the point of the chain
    /// where headroom given away by boosting is taken back.
    private func applyPreamp(
        _ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int
    ) {
        guard currentPreampLinear != 1.0 else { return }
        let gain = Float(currentPreampLinear)
        var index = 0
        for _ in 0..<frames {
            samples[index] *= gain
            index += stride
        }
    }

    private func advanceSmoothing(frames: Int) {
        let step = min(1.0, Double(frames) / (sampleRate * Self.smoothingSeconds))

        if currentPreampLinear != targetPreampLinear {
            let next = currentPreampLinear + (targetPreampLinear - currentPreampLinear) * step
            currentPreampLinear =
                abs(next - targetPreampLinear) < 0.0005 ? targetPreampLinear : next
        }
        for i in 0..<filterCount {
            if filters[i].currentGain != filters[i].targetGain {
                var gain =
                    filters[i].currentGain + (filters[i].targetGain - filters[i].currentGain) * step
                if abs(gain - filters[i].targetGain) < 0.02 {
                    gain = filters[i].targetGain
                }
                filters[i].currentGain = gain
                filters[i].needsCoefficientUpdate = true
            }
            if filters[i].needsCoefficientUpdate {
                let parameters = filters[i].parameters
                // Coefficients come from the same `Biquad` the response curve is
                // drawn from, so the plot always matches the audio.
                if !parameters.isEnabled, !parameters.kind.usesGain {
                    filters[i].filter = .identity
                } else {
                    filters[i].filter = Biquad(
                        kind: parameters.kind,
                        frequency: parameters.frequency,
                        gain: filters[i].currentGain,
                        q: parameters.q,
                        sampleRate: sampleRate
                    )
                }
                filters[i].needsCoefficientUpdate = false
            }
        }
    }

    private func processChannel(
        _ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int, channel: Int
    ) {
        for i in 0..<filterCount {
            let filter = filters[i].filter
            // Identity filters are the common case — every band the user has not
            // touched — so skipping them keeps an untouched chain nearly free.
            if filter == .identity { continue }
            let b0 = filter.b0
            let b1 = filter.b1
            let b2 = filter.b2
            let a1 = filter.a1
            let a2 = filter.a2
            let slot = delayIndex(filter: i, channel: channel)
            var z1 = delays[slot]
            var z2 = delays[slot + 1]

            var index = 0
            for _ in 0..<frames {
                let x = Double(samples[index])
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                samples[index] = Float(y)
                index += stride
            }

            // Flush denormals so idle audio does not burn CPU.
            if abs(z1) < 1e-15 { z1 = 0 }
            if abs(z2) < 1e-15 { z2 = 0 }
            delays[slot] = z1
            delays[slot + 1] = z2
        }
    }
}
