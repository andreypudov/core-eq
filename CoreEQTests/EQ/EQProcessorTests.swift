import CoreAudio
import Foundation
import Testing

/// The audio path itself: what the user actually hears.
///
/// Everything else in this suite tests what the app *decides*; this tests what
/// it *does* to the samples. The processor is driven exactly as Core Audio
/// drives it — an input buffer list in, an output buffer list out — so these
/// exercise the real `render` entry point rather than some testable subset of
/// it.
struct EQProcessorTests {
    private let sampleRate = 48_000.0

    // MARK: - Driving the processor

    /// One render pass over `frames` of interleaved audio, returned as the
    /// processor left it.
    private func render(
        _ processor: EQProcessor,
        _ input: [Float],
        channels: Int = 1
    ) -> [Float] {
        var inputSamples = input
        var outputSamples = [Float](repeating: 0, count: input.count)
        let frames = input.count / channels

        return inputSamples.withUnsafeMutableBufferPointer { inPtr in
            outputSamples.withUnsafeMutableBufferPointer { outPtr in
                var inList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                        mData: inPtr.baseAddress
                    )
                )
                var outList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                        mData: outPtr.baseAddress
                    )
                )
                processor.render(input: &inList, output: &outList)
                return Array(UnsafeBufferPointer(start: outPtr.baseAddress, count: input.count))
            }
        }
    }

    private func sine(_ frequency: Double, frames: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).map { frame in
            amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    private func makeProcessor(filters: [EQFilter] = [], preamp: Double = 0) -> EQProcessor {
        let processor = EQProcessor()
        processor.setSampleRate(sampleRate)
        processor.setFilters(filters)
        processor.setPreamp(preamp)
        return processor
    }

    /// Gain changes are smoothed over ~50 ms, so a measurement taken on the
    /// first buffer would be measuring the ramp. This runs the processor until
    /// the smoothing has settled and returns the last buffer.
    private func renderSettled(
        _ processor: EQProcessor,
        _ input: [Float],
        channels: Int = 1,
        passes: Int = 12
    ) -> [Float] {
        var output: [Float] = []
        for _ in 0..<passes { output = render(processor, input, channels: channels) }
        return output
    }

    // MARK: - Passthrough

    /// Bypass has to be *bit-exact* passthrough, not merely inaudible: it is
    /// the control a listener uses to decide whether the equalizer is doing
    /// anything they want, and any processing at all would prejudice that.
    @Test func bypassIsBitExactPassthrough() {
        let processor = makeProcessor(
            filters: [EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)],
            preamp: -6
        )
        processor.setBypassed(true)

        let input = sine(1_000, frames: 512)
        let output = renderSettled(processor, input)

        #expect(output == input, "bypass altered the samples")
    }

    /// An empty chain is not a special case in the processor — it is a chain of
    /// no filters — but it still has to leave the audio alone.
    @Test func anEmptyChainLeavesTheAudioAlone() {
        let processor = makeProcessor()
        let input = sine(1_000, frames: 512)
        #expect(renderSettled(processor, input) == input)
    }

    /// A chain of 0 dB filters is identity in `Biquad`, so it must be identity
    /// here too — this is what makes "Flat" cost nothing.
    @Test func aFlatChainLeavesTheAudioAlone() {
        let processor = makeProcessor(filters: BuiltInProfiles.emptyBandChain())
        let input = sine(1_000, frames: 512)

        let output = renderSettled(processor, input)
        for (produced, expected) in zip(output, input) {
            #expect(produced.isClose(to: expected, within: 1e-6))
        }
    }

    // MARK: - Filtering

    @Test func aBoostRaisesTheLevelAtItsOwnFrequency() {
        let processor = makeProcessor(
            filters: [EQFilter(kind: .bell, frequency: 1_000, gain: 6, q: 1)]
        )
        let input = sine(1_000, frames: 2_048)
        let output = renderSettled(processor, input)

        let gain = 20 * log10(rms(output) / rms(input))
        #expect(
            gain.isClose(to: 6, within: 0.5), "a +6 dB bell should lift its own frequency by ~6 dB")
    }

    @Test func aCutLowersTheLevelAtItsOwnFrequency() {
        let processor = makeProcessor(
            filters: [EQFilter(kind: .bell, frequency: 1_000, gain: -6, q: 1)]
        )
        let input = sine(1_000, frames: 2_048)
        let output = renderSettled(processor, input)

        #expect((20 * log10(rms(output) / rms(input))).isClose(to: -6, within: 0.5))
    }

    /// The point of a bell: it works on its own frequency and leaves the rest
    /// of the spectrum where it was.
    @Test func aBellLeavesDistantFrequenciesAlone() {
        let processor = makeProcessor(
            filters: [EQFilter(kind: .bell, frequency: 8_000, gain: 12, q: 2)]
        )
        let input = sine(200, frames: 2_048)
        let output = renderSettled(processor, input)

        #expect((20 * log10(rms(output) / rms(input))).isClose(to: 0, within: 0.5))
    }

    @Test func aDisabledFilterDoesNothing() {
        let processor = makeProcessor(
            filters: [EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1, isEnabled: false)]
        )
        let input = sine(1_000, frames: 2_048)
        let output = renderSettled(processor, input)

        #expect((20 * log10(rms(output) / rms(input))).isClose(to: 0, within: 0.2))
    }

    /// Filters cascade, so their dB contributions add. Two +4 dB bells on the
    /// same frequency are +8 dB, which is exactly what the response curve draws
    /// and therefore what the user was promised.
    @Test func filtersOnTheSameFrequencyAdd() {
        let processor = makeProcessor(filters: [
            EQFilter(kind: .bell, frequency: 1_000, gain: 4, q: 1),
            EQFilter(kind: .bell, frequency: 1_000, gain: 4, q: 1),
        ])
        let input = sine(1_000, frames: 2_048)
        let output = renderSettled(processor, input)

        #expect((20 * log10(rms(output) / rms(input))).isClose(to: 8, within: 0.6))
    }

    /// The chain the processor runs is the same one the graph draws, so the
    /// level it produces has to match what `Biquad` predicts — otherwise the
    /// curve is decoration.
    @Test func theRenderedLevelMatchesTheDrawnCurve() {
        let chain = [
            EQFilter(kind: .lowShelf, frequency: 120, gain: 4, q: 0.7),
            EQFilter(kind: .bell, frequency: 1_000, gain: -5, q: 1.4),
            EQFilter(kind: .highShelf, frequency: 9_000, gain: 3, q: 0.7),
        ]
        let processor = makeProcessor(filters: chain)

        for frequency in [80.0, 300, 1_000, 3_000, 12_000] {
            let input = sine(frequency, frames: 4_096)
            let output = renderSettled(processor, input)
            let measured = 20 * log10(rms(output) / rms(input))
            let drawn = chain.reduce(0.0) {
                $0
                    + Biquad(filter: $1, sampleRate: sampleRate)
                    .magnitudeDB(at: frequency, sampleRate: sampleRate)
            }
            #expect(
                measured.isClose(to: drawn, within: 0.6),
                "at \(frequency) Hz the audio and the curve disagree")
        }
    }

    // MARK: - Preamp

    @Test func thePreampScalesTheOutput() {
        let processor = makeProcessor(preamp: -6)
        let input = sine(1_000, frames: 2_048)
        let output = renderSettled(processor, input)

        #expect((20 * log10(rms(output) / rms(input))).isClose(to: -6, within: 0.3))
    }

    /// Bypass short-circuits the whole block, the trim included. This is what
    /// makes the master switch a true bypass rather than "the filters off":
    /// with it on, nothing at all is applied.
    @Test func bypassSkipsThePreampToo() {
        let processor = makeProcessor(preamp: -12)
        processor.setBypassed(true)

        let input = sine(1_000, frames: 512)
        #expect(renderSettled(processor, input) == input)
    }

    // MARK: - Smoothing

    /// Gain changes ramp over ~50 ms rather than stepping, or every preset
    /// switch would click. The first buffer after a change must therefore be
    /// partway there, and a later one all the way.
    @Test func gainChangesRampRatherThanStep() {
        let processor = makeProcessor()
        // Short buffers for the ramp: 256 frames is 5 ms, a tenth of the
        // smoothing window, so the first one has to arrive part-way.
        let short = sine(1_000, frames: 256)
        _ = renderSettled(processor, short)

        processor.setFilters([EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)])
        let first = render(processor, short)
        #expect(
            20 * log10(rms(first) / rms(short)) < 11,
            "the new gain arrived in one step — that is a click")

        // Long buffers for the settled value: each pass restarts the sine at
        // phase zero, and a filter carrying state across that discontinuity
        // rings for a few samples. On 2048-frame buffers that is a rounding
        // error; on 256-frame ones it is most of the measurement.
        let settled = renderSettled(processor, sine(1_000, frames: 2_048), passes: 20)
        #expect(
            (20 * log10(rms(settled) / rms(sine(1_000, frames: 2_048)))).isClose(
                to: 12, within: 0.5))
    }

    // MARK: - Buffers and channels

    /// Stereo comes in interleaved, and each channel carries its own filter
    /// state. Feeding silence to one channel must not silence the other.
    @Test func channelsAreFilteredIndependently() {
        let processor = makeProcessor(
            filters: [EQFilter(kind: .bell, frequency: 1_000, gain: 6, q: 1)]
        )
        let mono = sine(1_000, frames: 1_024)
        var interleaved: [Float] = []
        for sample in mono {
            interleaved.append(sample)
            interleaved.append(0)
        }

        let output = renderSettled(processor, interleaved, channels: 2)
        let left = stride(from: 0, to: output.count, by: 2).map { output[$0] }
        let right = stride(from: 1, to: output.count, by: 2).map { output[$0] }

        #expect(rms(left) > 0.1, "the left channel lost its signal")
        #expect(rms(right).isClose(to: 0, within: 1e-6), "silence leaked into the right channel")
    }

    /// A render that asks for more than the input holds must produce silence
    /// for the remainder rather than whatever the buffer happened to contain.
    @Test func aShortInputIsPaddedWithSilence() {
        let processor = makeProcessor()
        var input = [Float](repeating: 0.5, count: 64)
        var output = [Float](repeating: 99, count: 128)

        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                var inList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(64 * MemoryLayout<Float>.size),
                        mData: inPtr.baseAddress
                    )
                )
                var outList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(128 * MemoryLayout<Float>.size),
                        mData: outPtr.baseAddress
                    )
                )
                processor.render(input: &inList, output: &outList)
            }
        }

        #expect(output[64...].allSatisfy { $0 == 0 }, "the tail was left as it was found")
    }

    @Test func anEmptyRenderIsHarmless() {
        let processor = makeProcessor()
        #expect(render(processor, []) == [])
    }

    /// The chain is capped, and a chain longer than the cap must be truncated
    /// rather than overrun the fixed-size filter array.
    @Test func theChainIsCappedRatherThanOverrunning() {
        let tooMany = (0..<(EQProcessor.maxFilters * 2)).map { index in
            EQFilter(kind: .bell, frequency: 100 + Double(index), gain: 1, q: 1)
        }
        let processor = makeProcessor(filters: tooMany)

        let input = sine(1_000, frames: 512)
        let output = renderSettled(processor, input)
        #expect(output.allSatisfy { $0.isFinite }, "the render produced non-finite samples")
    }

    // MARK: - Sample rate

    /// The engine can be handed a new sample rate when the output device
    /// changes, and the coefficients have to be rebuilt for it — the same
    /// filter at 44.1 kHz and 48 kHz is not the same set of numbers.
    @Test func changingTheSampleRateRebuildsTheCoefficients() {
        let processor = EQProcessor()
        processor.setSampleRate(44_100)
        processor.setFilters([EQFilter(kind: .bell, frequency: 1_000, gain: 6, q: 1)])

        let at44 = renderSettled(processor, sine(1_000, frames: 2_048))
        processor.setSampleRate(sampleRate)
        let at48 = renderSettled(processor, sine(1_000, frames: 2_048))

        // Both should land on +6 dB at their own rate; the point is that the
        // second is not still running the first rate's coefficients.
        let reference = sine(1_000, frames: 2_048)
        #expect((20 * log10(rms(at44) / rms(reference))).isClose(to: 6, within: 0.8))
        #expect((20 * log10(rms(at48) / rms(reference))).isClose(to: 6, within: 0.8))
    }

    // MARK: - Device layouts

    /// Drives one render with an input list and an output list that need not
    /// match, which is the case every layout below is about and the one the
    /// helpers above cannot express.
    ///
    /// `inputChannels` describes a single interleaved tap buffer.
    /// `outputBuffers` gives the channel count of each output buffer, so
    /// `[8]` is one interleaved eight channel buffer and `[2, 2]` is one buffer
    /// per sub-device. Returns the output buffers separately, as the device
    /// would see them.
    private func renderAcrossLayout(
        _ processor: EQProcessor,
        input: [Float],
        inputChannels: Int,
        outputBuffers: [Int],
        frames: Int
    ) -> [[Float]] {
        var inputSamples = input

        // Allocated rather than taken from Swift arrays: several buffers have to
        // be live at once inside one call, and nesting
        // `withUnsafeMutableBufferPointer` over an array of arrays is an
        // exclusivity violation.
        let storage = outputBuffers.map { channels in
            UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
        }
        for (index, channels) in outputBuffers.enumerated() {
            storage[index].initialize(repeating: 99, count: frames * channels)
        }
        defer {
            for (index, channels) in outputBuffers.enumerated() {
                storage[index].deinitialize(count: frames * channels)
                storage[index].deallocate()
            }
        }

        // An `AudioBufferList` with more than one buffer is a variable-length C
        // struct, so it has to be built in raw memory rather than declared.
        let bytes =
            MemoryLayout<AudioBufferList>.size
            + max(0, outputBuffers.count - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let outList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        outList.pointee.mNumberBuffers = UInt32(outputBuffers.count)
        let outABL = UnsafeMutableAudioBufferListPointer(outList)
        for (index, channels) in outputBuffers.enumerated() {
            outABL[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage[index])
            )
        }

        inputSamples.withUnsafeMutableBufferPointer { inPtr in
            var inList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(inputChannels),
                    mDataByteSize: UInt32(input.count * MemoryLayout<Float>.size),
                    mData: inPtr.baseAddress
                )
            )
            processor.render(input: &inList, output: outList)
        }

        return outputBuffers.enumerated().map { index, channels in
            Array(UnsafeBufferPointer(start: storage[index], count: frames * channels))
        }
    }

    /// A stereo ramp whose two channels are distinguishable: left counts up,
    /// right counts down, so a channel landing in the wrong place is visible
    /// rather than merely wrong in level.
    private func stereoRamp(frames: Int) -> [Float] {
        (0..<frames).flatMap { [Float($0 + 1), -Float($0 + 1)] }
    }

    /// The multichannel bug. A stereo tap against a device presenting eight
    /// channels must fill the front pair and silence the rest — not pack four
    /// frames of stereo into one frame of eight and zero the remaining 75%,
    /// which is what pairing buffers by position did.
    @Test func aStereoTapFillsOnlyTheFrontPairOfAWideDevice() {
        let processor = makeProcessor()
        let frames = 8
        let output = renderAcrossLayout(
            processor, input: stereoRamp(frames: frames), inputChannels: 2,
            outputBuffers: [8], frames: frames
        )[0]

        for frame in 0..<frames {
            let base = frame * 8
            #expect(output[base] == Float(frame + 1), "left channel misplaced at frame \(frame)")
            #expect(
                output[base + 1] == -Float(frame + 1), "right channel misplaced at frame \(frame)")
            #expect(
                output[(base + 2)..<(base + 8)].allSatisfy { $0 == 0 },
                "frame \(frame) put audio in channels the tap does not feed")
        }
    }

    /// The aggregate case: one buffer per sub-device. The stereo pair belongs to
    /// the main sub-device, and the second device gets silence rather than
    /// whatever its buffer happened to hold.
    @Test func aStereoTapFeedsTheMainSubDeviceOfAnAggregate() {
        let processor = makeProcessor()
        let frames = 8
        let output = renderAcrossLayout(
            processor, input: stereoRamp(frames: frames), inputChannels: 2,
            outputBuffers: [2, 2], frames: frames
        )

        #expect(output[0] == stereoRamp(frames: frames), "the main sub-device lost the audio")
        #expect(output[1].allSatisfy { $0 == 0 }, "the second sub-device was left uninitialised")
    }

    /// A fully non-interleaved device: one channel per buffer. Left and right
    /// land in different buffers, which no amount of buffer pairing gets right.
    @Test func aStereoTapSplitsAcrossNonInterleavedBuffers() {
        let processor = makeProcessor()
        let frames = 8
        let output = renderAcrossLayout(
            processor, input: stereoRamp(frames: frames), inputChannels: 2,
            outputBuffers: [1, 1], frames: frames
        )

        #expect(output[0] == (0..<frames).map { Float($0 + 1) }, "left channel misplaced")
        #expect(output[1] == (0..<frames).map { -Float($0 + 1) }, "right channel misplaced")
    }

    /// An output list wider than the tap must not leave the extra channels
    /// carrying stale audio, which on a real device is the previous block.
    @Test func channelsTheTapDoesNotFeedAreSilenced() {
        let processor = makeProcessor()
        let frames = 4
        let output = renderAcrossLayout(
            processor, input: stereoRamp(frames: frames), inputChannels: 2,
            outputBuffers: [2, 6], frames: frames
        )

        #expect(output[1].allSatisfy { $0 == 0 }, "a channel the tap never wrote kept its contents")
    }

    /// The tap is found by its format, not by being first. An aggregate is free
    /// to order the input list however it likes.
    @Test func theTapIsFoundEvenWhenItIsNotTheFirstInputBuffer() {
        let processor = makeProcessor()
        let frames = 4
        var unrelated = [Float](repeating: 0.25, count: frames * 4)
        var tap = stereoRamp(frames: frames)
        var output = [Float](repeating: 99, count: frames * 2)

        unrelated.withUnsafeMutableBufferPointer { firstPtr in
            tap.withUnsafeMutableBufferPointer { tapPtr in
                output.withUnsafeMutableBufferPointer { outPtr in
                    let bytes = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
                    let raw = UnsafeMutableRawPointer.allocate(
                        byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
                    defer { raw.deallocate() }
                    let inList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
                    inList.pointee.mNumberBuffers = 2
                    let inABL = UnsafeMutableAudioBufferListPointer(inList)
                    // A four channel buffer first, the stereo tap second.
                    inABL[0] = AudioBuffer(
                        mNumberChannels: 4,
                        mDataByteSize: UInt32(frames * 4 * MemoryLayout<Float>.size),
                        mData: firstPtr.baseAddress)
                    inABL[1] = AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                        mData: tapPtr.baseAddress)

                    var outList = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2,
                            mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                            mData: outPtr.baseAddress
                        )
                    )
                    processor.render(input: inList, output: &outList)
                }
            }
        }

        #expect(
            output == stereoRamp(frames: frames), "the wrong input buffer was taken for the tap")
    }

    /// An output list with no buffers at all — what an aggregate built around an
    /// unusable device hands over. The engine refuses to start one of those, so
    /// this only asserts the render path does not fault on it.
    @Test func anOutputListWithNoBuffersIsHarmless() {
        let processor = makeProcessor()
        let frames = 4
        var input = stereoRamp(frames: frames)

        input.withUnsafeMutableBufferPointer { inPtr in
            var inList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                    mData: inPtr.baseAddress
                )
            )
            var outList = AudioBufferList(
                mNumberBuffers: 0,
                mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
            )
            processor.render(input: &inList, output: &outList)
        }
    }

    /// The EQ has to follow the audio to wherever the layout put it, not run
    /// over the head of the first buffer.
    @Test func theChainRunsOnTheChannelsTheAudioWasPlacedIn() {
        let boost = EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)
        let processor = makeProcessor(filters: [boost])
        let frames = 256
        let tone = sine(1_000, frames: frames)
        let stereo = tone.flatMap { [$0, $0] }

        var last: [[Float]] = []
        for _ in 0..<12 {
            last = renderAcrossLayout(
                processor, input: stereo, inputChannels: 2, outputBuffers: [8], frames: frames)
        }

        let left = stride(from: 0, to: frames * 8, by: 8).map { last[0][$0] }
        #expect(rms(left) > rms(tone) * 1.5, "the boost never reached the placed channel")
        let unfed = stride(from: 4, to: frames * 8, by: 8).map { last[0][$0] }
        #expect(
            unfed.allSatisfy { $0 == 0 }, "the chain wrote into a channel the tap does not feed")
    }

    // MARK: - Multichannel

    /// Interleaved frames where channel `c` carries a value identifying itself,
    /// so a channel arriving in the wrong place is visible.
    private func identifiableChannels(channels: Int, frames: Int) -> [Float] {
        (0..<frames).flatMap { frame in
            (0..<channels).map { Float(($0 + 1) * 100 + frame) }
        }
    }

    /// A tap that is not a stereo mixdown: every channel it delivers reaches the
    /// device, in order and untouched.
    @Test func aMultichannelTapCarriesEveryChannel() {
        let processor = makeProcessor()
        processor.setOutputLayout(.init(tapChannels: 6, destinations: Array(0..<6)))
        let frames = 8
        let input = identifiableChannels(channels: 6, frames: frames)

        let output = renderAcrossLayout(
            processor, input: input, inputChannels: 6, outputBuffers: [6], frames: frames)[0]

        #expect(output == input, "a channel was dropped, reordered, or altered")
    }

    /// Delay lines are per channel. Feeding every channel the same signal must
    /// produce the same output on every channel — if any state were shared, the
    /// channels would diverge as the filter rings.
    @Test func everyChannelKeepsItsOwnFilterState() {
        let boost = EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)
        let processor = makeProcessor(filters: [boost])
        processor.setOutputLayout(.init(tapChannels: 6, destinations: Array(0..<6)))
        let frames = 512
        let tone = sine(1_000, frames: frames)
        let input = tone.flatMap { sample in [Float](repeating: sample, count: 6) }

        var last: [Float] = []
        for _ in 0..<12 {
            last =
                renderAcrossLayout(
                    processor, input: input, inputChannels: 6, outputBuffers: [6], frames: frames)[
                    0]
        }

        let first = stride(from: 0, to: frames * 6, by: 6).map { last[$0] }
        for channel in 1..<6 {
            let samples = stride(from: channel, to: frames * 6, by: 6).map { last[$0] }
            #expect(samples == first, "channel \(channel) diverged from channel 0")
        }
        #expect(rms(first) > rms(tone) * 1.5, "the boost never reached the channels")
    }

    /// The stereo pair goes where the device says it keeps one, which the Core
    /// Audio header is explicit need not be the first two channels.
    @Test func theStereoPairFollowsTheDevicesPreferredChannels() {
        let processor = makeProcessor()
        processor.setOutputLayout(.init(tapChannels: 2, destinations: [2, 3]))
        let frames = 4

        let output = renderAcrossLayout(
            processor, input: stereoRamp(frames: frames), inputChannels: 2,
            outputBuffers: [6], frames: frames
        )[0]

        for frame in 0..<frames {
            let base = frame * 6
            #expect(output[base + 2] == Float(frame + 1), "left did not land on channel 2")
            #expect(output[base + 3] == -Float(frame + 1), "right did not land on channel 3")
            #expect(
                output[base] == 0 && output[base + 1] == 0,
                "audio reached channels the device does not use for stereo")
        }
    }

    /// A tap wider than the device drops the channels that have nowhere to go,
    /// rather than writing past the end of a buffer.
    @Test func channelsWithNowhereToGoAreDropped() {
        let processor = makeProcessor()
        processor.setOutputLayout(.init(tapChannels: 6, destinations: Array(0..<6)))
        let frames = 4
        let input = identifiableChannels(channels: 6, frames: frames)

        let output = renderAcrossLayout(
            processor, input: input, inputChannels: 6, outputBuffers: [2], frames: frames)[0]

        for frame in 0..<frames {
            #expect(output[frame * 2] == Float(100 + frame), "channel 0 was lost")
            #expect(output[frame * 2 + 1] == Float(200 + frame), "channel 1 was lost")
        }
    }

    /// The chain applies to every channel, LFE included. That is the policy —
    /// channel roles are not reliably reported, so a rule that depends on them
    /// would behave differently from device to device with nothing to explain it.
    @Test func theChainAppliesUniformlyToEveryChannel() {
        let boost = EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)
        let processor = makeProcessor(filters: [boost])
        processor.setOutputLayout(.init(tapChannels: 6, destinations: Array(0..<6)))
        let frames = 512
        let tone = sine(1_000, frames: frames)
        let input = tone.flatMap { sample in [Float](repeating: sample, count: 6) }

        var last: [Float] = []
        for _ in 0..<12 {
            last =
                renderAcrossLayout(
                    processor, input: input, inputChannels: 6, outputBuffers: [6], frames: frames)[
                    0]
        }

        for channel in 0..<6 {
            let samples = stride(from: channel, to: frames * 6, by: 6).map { last[$0] }
            #expect(rms(samples) > rms(tone) * 1.5, "channel \(channel) was left unequalized")
        }
    }

    // MARK: - Every channel, on and off

    /// Bypass on a wide device.
    ///
    /// `bypassIsBitExactPassthrough` covers one channel, which is the case that
    /// was never in doubt. Switching the equalizer off while playing to a
    /// sixteen channel device has to hand every one of those channels back
    /// untouched — the copy runs before the bypass check, so a mistake here is
    /// silence or scrambling rather than a wrong gain.
    @Test func bypassIsBitExactOnEveryChannel() {
        let processor = makeProcessor(
            filters: [EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)],
            preamp: -6
        )
        processor.setOutputLayout(.init(tapChannels: 16, destinations: Array(0..<16)))
        processor.setBypassed(true)

        let frames = 64
        let input = identifiableChannels(channels: 16, frames: frames)

        var output: [Float] = []
        for _ in 0..<4 {
            output =
                renderAcrossLayout(
                    processor, input: input, inputChannels: 16, outputBuffers: [16], frames: frames)[
                    0]
        }

        #expect(output == input, "bypass altered a wide device's samples")
    }

    /// The output trim is the last stage of the chain, so it has to reach every
    /// channel the audio was placed in — not just the pair the spectrum reads.
    @Test func thePreampScalesEveryChannel() {
        let processor = makeProcessor(preamp: -6)
        processor.setOutputLayout(.init(tapChannels: 8, destinations: Array(0..<8)))

        let frames = 512
        let tone = sine(1_000, frames: frames)
        let input = tone.flatMap { sample in [Float](repeating: sample, count: 8) }

        var output: [Float] = []
        for _ in 0..<24 {
            output =
                renderAcrossLayout(
                    processor, input: input, inputChannels: 8, outputBuffers: [8], frames: frames)[
                    0]
        }

        for channel in 0..<8 {
            let samples = stride(from: channel, to: frames * 8, by: 8).map { output[$0] }
            let gain = 20 * log10(rms(samples) / rms(tone))
            #expect(
                abs(gain + 6) < 0.3,
                "channel \(channel) was trimmed by \(gain) dB rather than -6")
        }
    }

    /// Taps are separate buffers and Core Audio does not promise they carry the
    /// same number of frames. A short one must not shorten or scramble the
    /// others, and must not be read past its end.
    @Test func aShortTapDoesNotDisturbTheOthers() {
        let processor = makeProcessor()
        processor.setOutputLayout(
            .init(
                tapChannels: 4, destinations: [0, 1, 2, 3], tapBufferIndex: 0,
                sourceBuffers: [0, 0, 1, 1], sourceChannels: [0, 1, 0, 1],
                primaryTapChannels: 2))

        let frames = 8
        let full = stereoRamp(frames: frames)
        let short = stereoRamp(frames: frames / 2)

        let output = renderAcrossInputBuffers(
            processor, inputBuffers: [full, short], inputChannels: 2,
            outputChannels: 4, frames: frames)

        // The full tap is intact across every frame.
        for frame in 0..<frames {
            #expect(output[frame * 4] == Float(frame + 1), "the full tap was disturbed")
            #expect(output[frame * 4 + 1] == -Float(frame + 1), "the full tap was disturbed")
        }
        // The short tap contributed what it had, and silence after it.
        for frame in 0..<(frames / 2) {
            #expect(output[frame * 4 + 2] == Float(frame + 1), "the short tap was not placed")
        }
        for frame in (frames / 2)..<frames {
            #expect(
                output[frame * 4 + 2] == 0 && output[frame * 4 + 3] == 0,
                "the short tap was read past its end")
        }
    }

    /// Each channel gets the chain's response *at its own frequency*.
    ///
    /// `theRenderedLevelMatchesTheDrawnCurve` proves this for one channel. A
    /// per-channel delay line that was shared, or a channel reading another's
    /// samples, would still pass that test and fail this one: six channels are
    /// driven with six different tones, and each has to come out at the gain the
    /// curve predicts for its own tone.
    ///
    /// Measured against real hardware at these exact frequencies, through a
    /// sixteen channel device, the worst disagreement was 0.01 dB.
    @Test func everyChannelGetsTheCurveAtItsOwnFrequency() {
        let boost = EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)
        let processor = makeProcessor(filters: [boost])
        let channels = 6
        let tones = [200.0, 300.0, 400.0, 500.0, 600.0, 700.0]
        let frames = 4_096

        let sources = tones.map { sine($0, frames: frames) }
        var input = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                input[frame * channels + channel] = sources[channel][frame]
            }
        }

        processor.setOutputLayout(
            .init(tapChannels: channels, destinations: Array(0..<channels)))

        var output: [Float] = []
        for _ in 0..<12 {
            output =
                renderAcrossLayout(
                    processor, input: input, inputChannels: channels,
                    outputBuffers: [channels], frames: frames)[0]
        }

        let biquad = Biquad(filter: boost, sampleRate: sampleRate)
        for channel in 0..<channels {
            let rendered = stride(from: channel, to: frames * channels, by: channels)
                .map { output[$0] }
            let measured = 20 * log10(rms(rendered) / rms(sources[channel]))
            let predicted = biquad.magnitudeDB(at: tones[channel], sampleRate: sampleRate)
            #expect(
                abs(measured - predicted) < 0.5,
                "channel \(channel) at \(tones[channel]) Hz measured \(measured) dB against \(predicted) dB on the curve"
            )
        }
    }

    // MARK: - The spectrum tap

    /// The analyzer draws what reaches the speakers, so the tap has to carry
    /// the *processed* output, not the input.
    @Test func theSpectrumTapCarriesTheProcessedOutput() {
        let processor = makeProcessor(
            filters: [EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)]
        )
        let input = sine(1_000, frames: 2_048)
        let output = renderSettled(processor, input)

        var tapped = [Float](repeating: 0, count: 2_048)
        let written = processor.spectrumBuffer.snapshot(into: &tapped)
        #expect(written > 0, "nothing reached the spectrum buffer")
        #expect(rms(tapped).isClose(to: rms(output), within: 0.02))
        #expect(rms(tapped) > rms(input) * 1.5, "the tap is carrying the input")
    }
    // MARK: - Finding the tap among several input buffers

    /// Renders with an input list of several buffers, as an aggregate built on a
    /// duplex device presents it: the device's own input buffers first, the tap
    /// after them. `inputBuffers` gives each buffer's samples, interleaved.
    private func renderAcrossInputBuffers(
        _ processor: EQProcessor,
        inputBuffers: [[Float]],
        inputChannels: Int,
        outputChannels: Int,
        frames: Int
    ) -> [Float] {
        let storage = inputBuffers.map { samples -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            p.initialize(from: samples, count: samples.count)
            return p
        }
        defer {
            for (index, samples) in inputBuffers.enumerated() {
                storage[index].deinitialize(count: samples.count)
                storage[index].deallocate()
            }
        }

        // Variable-length C struct, so it has to be built in raw memory.
        let bytes =
            MemoryLayout<AudioBufferList>.size
            + max(0, inputBuffers.count - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let inList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        inList.pointee.mNumberBuffers = UInt32(inputBuffers.count)
        let inABL = UnsafeMutableAudioBufferListPointer(inList)
        for (index, samples) in inputBuffers.enumerated() {
            inABL[index] = AudioBuffer(
                mNumberChannels: UInt32(inputChannels),
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage[index])
            )
        }

        var outputSamples = [Float](repeating: 0, count: frames * outputChannels)
        return outputSamples.withUnsafeMutableBufferPointer { outPtr in
            var outList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(outputChannels),
                    mDataByteSize: UInt32(frames * outputChannels * MemoryLayout<Float>.size),
                    mData: outPtr.baseAddress
                )
            )
            processor.render(input: inList, output: &outList)
            return Array(UnsafeBufferPointer(start: outPtr.baseAddress, count: outPtr.count))
        }
    }

    /// The BlackHole 16ch bug, at the level the samples actually move.
    ///
    /// A duplex output device contributes an input buffer of its own, listed
    /// before the tap's. When it is as wide as the tap, finding the tap by
    /// channel count returns the device's input instead — and because the tap
    /// mutes every other process at the hardware, that buffer is silent. The
    /// symptom was a completely silent Mac with the engine reporting `running`.
    @Test func theTapIsFoundPastTheDevicesOwnInputBuffer() {
        let processor = makeProcessor()
        let frames = 8
        processor.setOutputLayout(
            EQProcessor.OutputLayout(
                tapChannels: 2, destinations: [0, 1], tapBufferIndex: 1))

        let output = renderAcrossInputBuffers(
            processor,
            inputBuffers: [
                [Float](repeating: 0, count: frames * 2),  // the device's own input: silent
                stereoRamp(frames: frames),  // the tap
            ],
            inputChannels: 2, outputChannels: 2, frames: frames)

        #expect(output == stereoRamp(frames: frames))
    }

    /// The offset is not a fixed "skip one": an output-only device has no input
    /// buffer of its own and the tap really is first.
    @Test func theTapIsStillFoundWhenItIsTheOnlyInputBuffer() {
        let processor = makeProcessor()
        let frames = 8
        processor.setOutputLayout(
            EQProcessor.OutputLayout(
                tapChannels: 2, destinations: [0, 1], tapBufferIndex: 0))

        let output = renderAcrossInputBuffers(
            processor,
            inputBuffers: [stereoRamp(frames: frames)],
            inputChannels: 2, outputChannels: 2, frames: frames)

        #expect(output == stereoRamp(frames: frames))
    }

    /// A described position that is not there means the description is wrong,
    /// and dropping every block would be the worst answer available. The search
    /// that used to be the only path stays as the fallback.
    @Test func aTapIndexBeyondTheListFallsBackToSearching() {
        let processor = makeProcessor()
        let frames = 8
        processor.setOutputLayout(
            EQProcessor.OutputLayout(
                tapChannels: 2, destinations: [0, 1], tapBufferIndex: 7))

        let output = renderAcrossInputBuffers(
            processor,
            inputBuffers: [stereoRamp(frames: frames)],
            inputChannels: 2, outputChannels: 2, frames: frames)

        #expect(output == stereoRamp(frames: frames))
    }

    // MARK: - Wide devices

    /// Renders into an output list whose buffers may differ in *both* channel
    /// count and length, as `(channels, frames)` pairs. `renderAcrossLayout`
    /// gives every buffer the same length, which cannot express a device whose
    /// buffers disagree, or one presenting an empty buffer among real ones.
    private func renderAcrossUnevenLayout(
        _ processor: EQProcessor,
        input: [Float],
        inputChannels: Int,
        outputBuffers: [(channels: Int, frames: Int)]
    ) -> [[Float]] {
        var inputSamples = input

        let counts = outputBuffers.map { $0.channels * $0.frames }
        let storage = counts.map { count -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count))
            p.initialize(repeating: 99, count: max(1, count))
            return p
        }
        defer {
            for (index, count) in counts.enumerated() {
                storage[index].deinitialize(count: max(1, count))
                storage[index].deallocate()
            }
        }

        let bytes =
            MemoryLayout<AudioBufferList>.size
            + max(0, outputBuffers.count - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let outList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        outList.pointee.mNumberBuffers = UInt32(outputBuffers.count)
        let outABL = UnsafeMutableAudioBufferListPointer(outList)
        for (index, buffer) in outputBuffers.enumerated() {
            outABL[index] = AudioBuffer(
                mNumberChannels: UInt32(buffer.channels),
                mDataByteSize: UInt32(counts[index] * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage[index])
            )
        }

        inputSamples.withUnsafeMutableBufferPointer { inPtr in
            var inList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(inputChannels),
                    mDataByteSize: UInt32(input.count * MemoryLayout<Float>.size),
                    mData: inPtr.baseAddress
                )
            )
            processor.render(input: &inList, output: outList)
        }

        return counts.enumerated().map { index, count in
            Array(UnsafeBufferPointer(start: storage[index], count: count))
        }
    }

    /// The full width the processor supports, which is also exactly what
    /// BlackHole 16ch and a 7.1.4 layout present. Everything else multichannel
    /// here runs six channels, so the ceiling itself was never rendered through.
    @Test func aSixteenChannelTapCarriesEveryChannel() {
        let channels = EQProcessor.maxChannels
        let processor = makeProcessor()
        processor.setOutputLayout(
            .init(tapChannels: channels, destinations: Array(0..<channels)))
        let frames = 8
        let input = identifiableChannels(channels: channels, frames: frames)

        let output = renderAcrossLayout(
            processor, input: input, inputChannels: channels,
            outputBuffers: [channels], frames: frames)[0]

        #expect(output == input, "a channel was dropped, reordered, or altered at full width")
    }

    /// Delay lines are indexed `(filter * maxChannels + channel) * 2`, so the
    /// last channel sits at the end of the allocation. An off-by-one there would
    /// have channel 15 read another filter's state — or run off the end — and
    /// six-channel tests can never reach it.
    @Test func theTopChannelKeepsItsOwnFilterState() {
        let channels = EQProcessor.maxChannels
        // Two filters, not one: the index is `filter * maxChannels + channel`,
        // so a stride that is too short makes filter 1's channel 0 collide with
        // filter 0's channel 8 — invisible while there is only one filter.
        let processor = makeProcessor(filters: [
            EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1),
            EQFilter(kind: .bell, frequency: 4_000, gain: -9, q: 1),
        ])
        processor.setOutputLayout(
            .init(tapChannels: channels, destinations: Array(0..<channels)))
        let frames = 512
        let tone = sine(1_000, frames: frames)
        let input = tone.flatMap { sample in [Float](repeating: sample, count: channels) }

        var last: [Float] = []
        for _ in 0..<12 {
            last =
                renderAcrossLayout(
                    processor, input: input, inputChannels: channels,
                    outputBuffers: [channels], frames: frames)[0]
        }

        let first = stride(from: 0, to: frames * channels, by: channels).map { last[$0] }
        for channel in 1..<channels {
            let samples = stride(from: channel, to: frames * channels, by: channels).map {
                last[$0]
            }
            #expect(samples == first, "channel \(channel) diverged from channel 0")
        }
        #expect(rms(first) > rms(tone) * 1.5, "the boost never reached the channels")
    }

    /// A wide tap crossing a buffer boundary. Only a *stereo* tap has ever been
    /// split across buffers here, and stereo never exercises the seam: channel 8
    /// is the first channel of the second buffer, and the global-channel walk in
    /// `destination` has to find it there rather than at offset 8 of the first.
    @Test func aWideTapSpansSeveralOutputBuffers() {
        let channels = EQProcessor.maxChannels
        let processor = makeProcessor()
        processor.setOutputLayout(
            .init(tapChannels: channels, destinations: Array(0..<channels)))
        let frames = 8
        let input = identifiableChannels(channels: channels, frames: frames)

        let output = renderAcrossLayout(
            processor, input: input, inputChannels: channels,
            outputBuffers: [8, 8], frames: frames)

        for frame in 0..<frames {
            for channel in 0..<8 {
                #expect(
                    output[0][frame * 8 + channel] == Float((channel + 1) * 100 + frame),
                    "channel \(channel) misplaced in the first buffer")
                #expect(
                    output[1][frame * 8 + channel] == Float((channel + 9) * 100 + frame),
                    "channel \(channel + 8) misplaced in the second buffer")
            }
        }
    }

    /// The aggregate shape at width: one stereo buffer per sub-device, eight of
    /// them. Every buffer boundary is a seam, so a global walk that drifts by a
    /// buffer shows up immediately.
    @Test func aWideTapSpansOneBufferPerStereoPair() {
        let channels = EQProcessor.maxChannels
        let processor = makeProcessor()
        processor.setOutputLayout(
            .init(tapChannels: channels, destinations: Array(0..<channels)))
        let frames = 4
        let input = identifiableChannels(channels: channels, frames: frames)

        let output = renderAcrossLayout(
            processor, input: input, inputChannels: channels,
            outputBuffers: [Int](repeating: 2, count: 8), frames: frames)

        for pair in 0..<8 {
            for frame in 0..<frames {
                #expect(
                    output[pair][frame * 2] == Float((pair * 2 + 1) * 100 + frame),
                    "left of pair \(pair) misplaced")
                #expect(
                    output[pair][frame * 2 + 1] == Float((pair * 2 + 2) * 100 + frame),
                    "right of pair \(pair) misplaced")
            }
        }
    }

    /// A tap wider than the processor carries. `maxChannels` is a real budget —
    /// the delay lines are allocated against it — so a 64 channel BlackHole, or
    /// any device beyond 7.1.4, is clamped rather than overrunning. The channels
    /// that fit must still be correct, and the rest must be silent rather than
    /// stale.
    ///
    /// This pins current behaviour, and current behaviour is a limitation: the
    /// audio past channel 15 is dropped.
    @Test func aTapWiderThanTheProcessorRoutesWhatItCan() {
        let channels = EQProcessor.maxChannels + 4
        let processor = makeProcessor()
        processor.setOutputLayout(
            .init(tapChannels: channels, destinations: Array(0..<channels)))
        let frames = 4
        let input = identifiableChannels(channels: channels, frames: frames)

        let output = renderAcrossLayout(
            processor, input: input, inputChannels: channels,
            outputBuffers: [channels], frames: frames)[0]

        for frame in 0..<frames {
            for channel in 0..<EQProcessor.maxChannels {
                #expect(
                    output[frame * channels + channel] == Float((channel + 1) * 100 + frame),
                    "channel \(channel) was lost inside the budget")
            }
            for channel in EQProcessor.maxChannels..<channels {
                #expect(
                    output[frame * channels + channel] == 0,
                    "channel \(channel) is past the budget and should be silent")
            }
        }
    }

    /// Buffers in one list need not be the same length. `place` reports the
    /// longest run it wrote, so the chain must re-clamp per channel or it would
    /// process past the end of the shorter buffer.
    @Test func aShorterOutputBufferIsNotOverrun() {
        let boost = EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)
        let processor = makeProcessor(filters: [boost])
        processor.setOutputLayout(.init(tapChannels: 4, destinations: Array(0..<4)))
        let frames = 8
        let input = identifiableChannels(channels: 4, frames: frames)

        let output = renderAcrossUnevenLayout(
            processor, input: input, inputChannels: 4,
            outputBuffers: [(channels: 2, frames: frames), (channels: 2, frames: frames / 2)])

        #expect(output[0].count == frames * 2)
        #expect(output[1].count == (frames / 2) * 2, "the short buffer changed length")
        #expect(output[1].allSatisfy { $0.isFinite }, "the short buffer was written past its end")
    }

    /// A device may present a buffer with no channels at all. Global channel
    /// numbering has to step over it, so channel 4 is the head of the *third*
    /// buffer, not of the empty one.
    @Test func anEmptyBufferInTheOutputListIsSkipped() {
        let processor = makeProcessor()
        processor.setOutputLayout(.init(tapChannels: 8, destinations: Array(0..<8)))
        let frames = 4
        let input = identifiableChannels(channels: 8, frames: frames)

        let output = renderAcrossUnevenLayout(
            processor, input: input, inputChannels: 8,
            outputBuffers: [
                (channels: 4, frames: frames),
                (channels: 0, frames: frames),
                (channels: 4, frames: frames),
            ])

        for frame in 0..<frames {
            for channel in 0..<4 {
                #expect(
                    output[0][frame * 4 + channel] == Float((channel + 1) * 100 + frame),
                    "channel \(channel) misplaced before the empty buffer")
                #expect(
                    output[2][frame * 4 + channel] == Float((channel + 5) * 100 + frame),
                    "channel \(channel + 4) did not step over the empty buffer")
            }
        }
    }

    // MARK: - Several taps, one per output stream

    /// The multi-stream device, end to end at the sample level. Two taps of two
    /// channels each arrive in two separate input buffers, and their four
    /// channels have to reassemble into the device's channels 0–3 in the right
    /// order. Reading either tap alone — which is what binding to the widest
    /// stream did — loses half the audio.
    @Test func severalTapsReassembleIntoOneDevice() {
        let processor = makeProcessor()
        let frames = 8
        processor.setOutputLayout(
            OutputPlan.layout(
                forTaps: OutputPlan.tapPlans(forStreams: [2, 2]), inputBuffers: 0))

        // Tap 0 carries device channels 0 and 1, tap 1 carries 2 and 3.
        let first = (0..<frames).flatMap { [Float(100 + $0), Float(200 + $0)] }
        let second = (0..<frames).flatMap { [Float(300 + $0), Float(400 + $0)] }

        let output = renderAcrossInputBuffers(
            processor, inputBuffers: [first, second],
            inputChannels: 2, outputChannels: 4, frames: frames)

        for frame in 0..<frames {
            #expect(output[frame * 4] == Float(100 + frame), "tap 0 channel 0 misplaced")
            #expect(output[frame * 4 + 1] == Float(200 + frame), "tap 0 channel 1 misplaced")
            #expect(output[frame * 4 + 2] == Float(300 + frame), "tap 1 channel 0 misplaced")
            #expect(output[frame * 4 + 3] == Float(400 + frame), "tap 1 channel 1 misplaced")
        }
    }

    /// The taps sit after the device's own input buffers, so a duplex
    /// multi-stream device offsets all of them — the two failure modes this file
    /// has found, together.
    @Test func severalTapsAreFoundPastTheDevicesOwnInput() {
        let processor = makeProcessor()
        let frames = 4
        processor.setOutputLayout(
            OutputPlan.layout(
                forTaps: OutputPlan.tapPlans(forStreams: [2, 2]), inputBuffers: 1))

        let deviceInput = [Float](repeating: 0, count: frames * 2)
        let first = (0..<frames).flatMap { [Float(100 + $0), Float(200 + $0)] }
        let second = (0..<frames).flatMap { [Float(300 + $0), Float(400 + $0)] }

        let output = renderAcrossInputBuffers(
            processor, inputBuffers: [deviceInput, first, second],
            inputChannels: 2, outputChannels: 4, frames: frames)

        for frame in 0..<frames {
            #expect(output[frame * 4] == Float(100 + frame), "tap 0 was read from the wrong buffer")
            #expect(
                output[frame * 4 + 2] == Float(300 + frame), "tap 1 was read from the wrong buffer")
        }
    }

    /// Every tap's channels get the chain, not just the first tap's. A device
    /// whose rear pair came through a second tap unequalized would be worse than
    /// one that dropped it, because it would sound almost right.
    @Test func theChainReachesEveryTap() {
        let boost = EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)
        let processor = makeProcessor(filters: [boost])
        let frames = 512
        processor.setOutputLayout(
            OutputPlan.layout(
                forTaps: OutputPlan.tapPlans(forStreams: [2, 2]), inputBuffers: 0))

        let tone = sine(1_000, frames: frames)
        let pair = tone.flatMap { [$0, $0] }

        var output: [Float] = []
        for _ in 0..<12 {
            output = renderAcrossInputBuffers(
                processor, inputBuffers: [pair, pair],
                inputChannels: 2, outputChannels: 4, frames: frames)
        }

        for channel in 0..<4 {
            let samples = stride(from: channel, to: frames * 4, by: 4).map { output[$0] }
            #expect(rms(samples) > rms(tone) * 1.5, "channel \(channel) was left unequalized")
        }
    }

    // MARK: - Silence, which decides when the device is released

    /// The measurement the whole idle behaviour rests on. Too eager and the
    /// audio path is released under someone listening; too reluctant and the
    /// Mac never sleeps, which is the bug it exists to fix.

    /// Counted from frames delivered, not from a clock. The render thread has no
    /// business reading the time, and frames are what the device actually did.
    @Test func silenceIsMeasuredInDeliveredAudio() {
        let processor = makeProcessor()
        let oneSecond = Int(sampleRate)

        _ = render(processor, [Float](repeating: 0, count: oneSecond))

        #expect(abs(processor.observed.silentSeconds - 1.0) < 0.001)
    }

    /// It accumulates across passes, because a device delivers a few hundred
    /// frames at a time and thirty seconds of quiet is thousands of those.
    @Test func silenceAccumulatesAcrossRenderPasses() {
        let processor = makeProcessor()
        let block = [Float](repeating: 0, count: 512)

        for _ in 0..<100 { _ = render(processor, block) }

        #expect(abs(processor.observed.silentSeconds - 100 * 512 / sampleRate) < 0.001)
    }

    /// Any sample at all ends the silence. Not a threshold: a passage at -60 dB
    /// is still someone listening, and releasing the device under them is the
    /// failure that matters.
    @Test func aSingleQuietSampleEndsTheSilence() {
        let processor = makeProcessor()
        _ = render(processor, [Float](repeating: 0, count: 4_800))
        #expect(processor.observed.silentSeconds > 0)

        var barelyAudible = [Float](repeating: 0, count: 4_800)
        barelyAudible[2_000] = 1e-6
        _ = render(processor, barelyAudible)

        #expect(processor.observed.silentSeconds == 0, "a quiet passage was counted as silence")
    }

    /// And music certainly does.
    @Test func audioKeepsTheSilenceAtZero() {
        let processor = makeProcessor()
        for _ in 0..<20 { _ = render(processor, sine(440, frames: 512)) }

        #expect(processor.observed.silentSeconds == 0)
    }

    /// Silence restarts after audio rather than resuming where it left off:
    /// what matters is the *current* run of quiet, not the total.
    @Test func silenceIsTheCurrentRunNotATotal() {
        let processor = makeProcessor()
        _ = render(processor, [Float](repeating: 0, count: 24_000))
        _ = render(processor, sine(440, frames: 512))
        _ = render(processor, [Float](repeating: 0, count: 4_800))

        #expect(abs(processor.observed.silentSeconds - 4_800 / sampleRate) < 0.001)
    }

    /// Resuming clears it. The engine has just been stopped for a while, and
    /// carrying the silence across would idle again on the next check —
    /// releasing the device moments after taking it back.
    @Test func resumingClearsTheSilence() {
        let processor = makeProcessor()
        _ = render(processor, [Float](repeating: 0, count: Int(sampleRate) * 40))
        #expect(processor.observed.silentSeconds > 30)

        processor.prepareForResume()

        #expect(processor.observed.silentSeconds == 0)
    }

    /// Resuming also clears filter state, because the delay lines describe audio
    /// from before the pause. Fed silence, a chain holding state rings; a chain
    /// that was reset is silent.
    @Test func resumingClearsFilterState() {
        let processor = makeProcessor(filters: [
            EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 8)
        ])
        _ = render(processor, sine(1_000, frames: 2_048, amplitude: 0.9))

        processor.prepareForResume()
        let afterReset = render(processor, [Float](repeating: 0, count: 512))

        #expect(afterReset.allSatisfy { $0 == 0 }, "stale filter state rang into the new audio")
    }

    // MARK: - Output level, which settles the noise reports

    /// The peak is kept for the life of the engine, not per block. The question
    /// a report answers is whether this ever happened, and a value that decays
    /// answers it only for whoever is watching at the time.
    @Test func thePeakSurvivesLaterQuiet() {
        let processor = makeProcessor()
        _ = render(processor, sine(440, frames: 512, amplitude: 0.8))
        let loud = processor.observed.peakLevel
        #expect(loud > 0.5)

        for _ in 0..<50 { _ = render(processor, [Float](repeating: 0, count: 512)) }

        #expect(processor.observed.peakLevel == loud, "the peak decayed and stopped being evidence")
    }

    /// Clipping is what a boosted preset does to material that had no headroom,
    /// and it is the first hypothesis for the open "sounds noisy" reports.
    @Test func aBoostedChainReportsWhatDidNotFit() {
        let processor = makeProcessor(
            filters: [EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)])
        for _ in 0..<20 { _ = render(processor, sine(1_000, frames: 512, amplitude: 0.95)) }

        #expect(processor.observed.peakLevel > 1.0)
        #expect(processor.observed.clippedSamples > 0)
    }

    /// A chain with headroom reports none, so the line means something when it
    /// is not empty.
    @Test func anUnboostedChainReportsNoClipping() {
        let processor = makeProcessor()
        for _ in 0..<20 { _ = render(processor, sine(1_000, frames: 512, amplitude: 0.5)) }

        #expect(processor.observed.clippedSamples == 0)
        #expect(processor.observed.peakLevel <= 1.0)
    }

    /// Bypass touches nothing, so there is nothing CoreEQ could have clipped —
    /// and measuring it would blame the app for the material.
    @Test func bypassMeasuresNothing() {
        let processor = makeProcessor(
            filters: [EQFilter(kind: .bell, frequency: 1_000, gain: 12, q: 1)])
        processor.setBypassed(true)
        for _ in 0..<20 { _ = render(processor, sine(1_000, frames: 512, amplitude: 0.95)) }

        #expect(processor.observed.clippedSamples == 0)
    }

}
