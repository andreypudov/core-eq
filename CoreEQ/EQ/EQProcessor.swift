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

    /// What the render thread noticed, for the diagnostics report and for
    /// `IdlePolicy`. See `RenderObservations` for why this is unsynchronised.
    nonisolated(unsafe) private(set) var observed = RenderObservations()

    /// Whether the engine is still proving the tap works.
    ///
    /// While true the render path watches the input and writes nothing. That is
    /// deliberate: during the proof the tap is *unmuted*, so every other
    /// process is still audible, and writing our copy as well would play
    /// everything twice.
    ///
    /// Unsynchronised for the same reason as `hasReceivedAudio`: written once
    /// per engine start from the main thread, read on the render thread, and a
    /// block either side of the change is of no consequence — one buffer of
    /// silence, or one buffer unprocessed.
    nonisolated(unsafe) var isProvingCapture = false

    /// Mono copy of the played-back output, tapped for the spectrum analyzer.
    /// 8192 samples is well beyond the analyzer's 4096-sample window, so the
    /// consumer can snapshot without the producer overtaking the read region.
    let spectrumBuffer = SpectrumAudioBuffer(capacity: 8_192)

    /// Flight recorder for sample-rate changes. Always on: it costs four stores
    /// a cycle, and the interval it measures is one nobody can reproduce on
    /// demand — it happens on someone else's headset, once, mid-call.
    let rateTrace = RateTrace()

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
    private var pendingFilters = [FilterBank.Parameters](
        repeating: FilterBank.Parameters(), count: EQProcessor.maxFilters)
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
    /// Where a staged chain is copied to while the lock is held, so the lock is
    /// released before the longer work of comparing it against what is running.
    /// Holding it across that would put the main thread in a position to block
    /// on the audio thread, which is the inversion the staging exists to avoid.
    private var stagedFilters = [FilterBank.Parameters](
        repeating: FilterBank.Parameters(), count: EQProcessor.maxFilters)
    private var stagedDestinations = [Int](repeating: -1, count: EQProcessor.maxChannels)
    private var stagedSourceBuffers = [Int](repeating: 0, count: EQProcessor.maxChannels)
    private var stagedSourceChannels = Array(0..<EQProcessor.maxChannels)
    /// Where the tap's channels go and how they are found in the buffer lists.
    /// See `BufferRouter`.
    private var router = BufferRouter()
    /// The chain itself, and everything the samples pass through. See
    /// `FilterBank`.
    private var bank = FilterBank()
    private var bypassed = false

    // MARK: - Control (any thread)

    /// Stages a chain for the render thread. Anything past `maxFilters` is
    /// dropped here rather than in the callback, so the render side never has to
    /// reason about a chain longer than its storage.
    func setFilters(_ newFilters: [EQFilter]) {
        let count = min(newFilters.count, FilterBank.maxFilters)
        lock.lock()
        for i in 0..<count {
            pendingFilters[i] = FilterBank.Parameters(newFilters[i])
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

    /// Forgets what the tap has delivered, for a fresh engine.
    /// Clears filter state across a pause in the audio.
    ///
    /// The delay lines hold the last samples processed. Resuming after a gap
    /// runs new audio against state that describes sound from minutes ago, which
    /// is the same discontinuity a channel or rate change causes — and those
    /// already reset. A few samples of transient is a click.
    func prepareForResume() {
        bank.resetAll()
        observed.silentSeconds = 0
    }

    func resetAudioObservation() {
        observed.reset()
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
        input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
        now: UnsafePointer<AudioTimeStamp>? = nil
    ) {
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outABL = UnsafeMutableAudioBufferListPointer(output)

        recordCycle(now, outABL)
        consumePendingParameters()

        // Silence first, then place. Every output channel the tap does not feed
        // has to end up silent rather than left as it was found, and so does the
        // tail of a buffer longer than the tap delivered. Clearing up front makes
        // both of those one memset instead of a special case each.
        for i in 0..<outABL.count {
            guard let data = outABL[i].mData else { continue }
            memset(data, 0, Int(outABL[i].mDataByteSize))
        }

        // Watched whether or not anything is written: while the tap is being
        // proved this is the only thing the render path is here to do.
        // Time is counted from the frames delivered rather than from a clock,
        // so it stays true when the IO thread is late and stops advancing the
        // moment the device stops calling us — which is what it means for there
        // to be no audio at all.
        var elapsed = 0.0
        if bank.sampleRate > 0, outABL.count > 0, outABL[0].mNumberChannels > 0 {
            let bytesPerFrame = MemoryLayout<Float>.size * Int(outABL[0].mNumberChannels)
            elapsed = Double(Int(outABL[0].mDataByteSize) / bytesPerFrame) / bank.sampleRate
        }
        observed.observe(input: inABL, seconds: elapsed)

        // Nothing is written while proving. The tap is unmuted then, so every
        // other process is still audible and adding our copy would double it.
        guard !isProvingCapture else {
            feedSpectrum(outABL)
            return
        }

        // Where the primary tap actually turned up, which may not be where it
        // was described. Resolved once per block rather than per channel.
        let substitute = router.substituteTapBuffer(in: inABL)
        let placed = router.place(inABL, into: outABL, substitute: substitute)
        observed.note(sourcePeak: placed.sourcePeak)

        if !bypassed, placed.frames > 0 {
            bank.advance(frames: placed.frames)
            equalize(outABL, frames: placed.frames)
        }

        feedSpectrum(outABL)
    }

    /// Whether any buffer holds a sample that is not zero.
    ///
    /// Stops at the first one, so on a Mac that is playing this costs a single
    /// comparison — and it is only called until the answer is yes.
    /// Copies each routed channel from the input channel the layout names to the
    /// output channel it names, and returns how many frames were written.
    ///
    /// Source and destination are both explicit. With one tap every source is
    /// the same buffer and the channels are read in order; with one tap per
    /// output stream they are not, and nothing here needs to know which case it
    /// is in.
    /// Locates one routed channel in the input list: which buffer it is in,
    /// where it starts, and how far apart its samples are. The mirror of
    /// `destination`, and nil on the same terms — a channel the input does not
    /// have is left silent rather than read from nowhere.
    /// Runs the chain and the output trim over the channels the tap was placed
    /// into. The rest of the device's channels are silence and stay that way.
    private func equalize(
        _ outABL: UnsafeMutableAudioBufferListPointer, frames: Int
    ) {
        for channel in 0..<router.routedChannels {
            guard let target = router.output(of: channel, in: outABL) else { continue }
            let count = min(frames, target.frames)
            bank.process(
                target.pointer, stride: target.stride, frames: count, channel: channel)
            bank.applyPreamp(target.pointer, stride: target.stride, frames: count)
            observed.observe(output: target.pointer, stride: target.stride, frames: count)
        }
    }

    /// Watches what the chain actually produced.
    ///
    /// Called only from `equalize`, which is deliberate: bypass passes samples
    /// through untouched, so there is nothing CoreEQ could have clipped and
    /// nothing worth the pass. The peak is kept for the life of the engine
    /// rather than per block — the question is whether this ever happened, and a
    /// value that decays answers it only for whoever is watching at the time.
    /// Locates one global output channel: which buffer holds it, where in that
    /// buffer it starts, and how far apart its samples are.
    ///
    /// Returns nil when the layout names a channel the device does not have,
    /// which is the honest answer — better a silent channel than a write past
    /// the end of a buffer.
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
    /// Hands a mono copy of the final output — equalized when enabled, the
    /// untouched passthrough when bypassed — to the spectrum buffer, so the
    /// analyzer always shows what is actually reaching the speakers.
    ///
    /// Reads the channels the audio was placed into rather than the head of the
    /// first buffer, which on a multichannel device is not where the audio is.
    private func feedSpectrum(_ outABL: UnsafeMutableAudioBufferListPointer) {
        guard router.routedChannels > 0,
            let left = router.output(of: 0, in: outABL), left.frames > 0
        else { return }
        // Average the pair when the map put it side by side in one buffer, which
        // is every interleaved device. Otherwise the first channel alone is an
        // honest enough picture for a backdrop.
        let right = router.routedChannels > 1 ? router.output(of: 1, in: outABL) : nil
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
    /// Clears one filter's delay lines across every channel. Called when a
    /// filter's shape changes, because the state describes the old response.
    /// Notes this cycle's cadence for `RateWindow` to read later.
    ///
    /// The frame count comes from the output list rather than from anything the
    /// tap logic works out, so it is available whatever else the cycle does —
    /// including while the tap is still being proved and nothing is written.
    private func recordCycle(
        _ now: UnsafePointer<AudioTimeStamp>?, _ outABL: UnsafeMutableAudioBufferListPointer
    ) {
        guard let now, outABL.count > 0 else { return }
        let channels = Int(outABL[0].mNumberChannels)
        guard channels > 0 else { return }
        let frames = Int(outABL[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)

        let timestamp = now.pointee
        rateTrace.record(
            hostTime: timestamp.mHostTime,
            sampleTime: timestamp.mFlags.contains(.sampleTimeValid) ? timestamp.mSampleTime : 0,
            frames: frames,
            configuredRate: bank.sampleRate)
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

        if let newTapChannels { router.setTapChannelCount(newTapChannels) }

        if let newTapBuffer, newTapBuffer != router.tapBufferIndex {
            router.setTapBuffer(newTapBuffer)
            // A different input buffer is different audio, so the delay lines
            // are describing something that is no longer arriving.
            bank.resetAll()
        }

        if let newRouted {
            let changed = router.differs(
                channels: newRouted, destinations: stagedDestinations,
                sourceBuffers: stagedSourceBuffers, sourceChannels: stagedSourceChannels)
            if changed {
                router.setRouting(
                    channels: newRouted, destinations: stagedDestinations,
                    sourceBuffers: stagedSourceBuffers, sourceChannels: stagedSourceChannels)
                // Different channels means the delay lines are describing audio
                // that is no longer there.
                bank.resetAll()
            }
        }

        if let newRate, bank.setSampleRate(newRate) {
            // The far edge of the stale window, and the only place it can be
            // timed: everything before this point ran on the old coefficients.
            rateTrace.mark(.coefficientsRecomputed, rate: newRate)
        }

        if let newFilterCount {
            bank.setFilters(stagedFilters, count: newFilterCount)
        }

        if let newPreamp {
            bank.setPreamp(dB: newPreamp)
        }

        if let newBypass, newBypass != bypassed {
            bypassed = newBypass
            // Coming back from bypass, the delay lines describe audio from
            // before it was switched off.
            if !bypassed { bank.resetAll() }
        }
    }
}
