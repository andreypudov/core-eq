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
}
