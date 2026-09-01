import Foundation
import Testing

/// The filter math is shared by the audio path and the response curve, so these
/// tests are what keeps the drawn curve honest about what you hear.
struct BiquadTests {
    private let sampleRate = 48_000.0

    private func bell(_ frequency: Double, _ gain: Double, q: Double = 1.41) -> Biquad {
        Biquad(kind: .bell, frequency: frequency, gain: gain, q: q, sampleRate: sampleRate)
    }

    // MARK: - The defining property

    /// A peaking filter's magnitude at its own centre frequency is exactly its
    /// gain. Everything else in the app leans on this: it is why the band
    /// handles line up with the sliders, and why subtracting a band's gain from
    /// the composite yields its neighbours' contribution.
    @Test func magnitudeAtCentreFrequencyEqualsGain() {
        for gain in [-12.0, -6.0, -0.5, 0.5, 3.0, 6.0, 12.0] {
            for frequency in [32.0, 250.0, 1_000.0, 8_000.0, 16_000.0] {
                #expect(
                    bell(frequency, gain).magnitudeDB(at: frequency, sampleRate: sampleRate)
                        .isClose(to: gain, within: 0.001), "\(gain) dB at \(frequency) Hz")
            }
        }
    }

    @Test func responseIsFlatFarFromCentreFrequency() {
        let filter = bell(1_000, 12)
        #expect(filter.magnitudeDB(at: 20, sampleRate: sampleRate).isClose(to: 0, within: 0.2))
        #expect(filter.magnitudeDB(at: 20_000, sampleRate: sampleRate).isClose(to: 0, within: 0.2))
    }

    @Test func higherQNarrowsTheBell() {
        // An octave away the wide filter should still be lifting appreciably
        // more than the narrow one.
        #expect(
            bell(1_000, 12, q: 0.7).magnitudeDB(at: 2_000, sampleRate: sampleRate)
                > bell(1_000, 12, q: 4.0).magnitudeDB(at: 2_000, sampleRate: sampleRate))
    }

    @Test func boostAndCutAreMirrored() {
        let boost = bell(1_000, 6)
        let cut = bell(1_000, -6)
        for probe in [500.0, 1_000.0, 2_000.0] {
            #expect(
                boost.magnitudeDB(at: probe, sampleRate: sampleRate).isClose(
                    to: -cut.magnitudeDB(at: probe, sampleRate: sampleRate), within: 0.001))
        }
    }

    /// The property the whole layered-chain idea rests on: cascaded biquads
    /// multiply in magnitude, so their dB contributions add exactly. If this
    /// ever stopped holding, the composite curve would no longer be the sum of
    /// its parts, and the graph would be lying about what is being heard.
    @Test func chainMagnitudesAddInDecibels() {
        let filters = [bell(125, 3), bell(180, 2, q: 0.8), bell(4_000, -4, q: 2)]
        for probe in [60.0, 125.0, 180.0, 1_000.0, 4_000.0, 12_000.0] {
            let summed = filters.reduce(0.0) {
                $0 + $1.magnitudeDB(at: probe, sampleRate: sampleRate)
            }
            let product = filters.reduce(1.0) {
                $0 * pow(10.0, $1.magnitudeDB(at: probe, sampleRate: sampleRate) / 20.0)
            }
            #expect(summed.isClose(to: 20.0 * log10(product), within: 1e-9), "at \(probe) Hz")
        }
    }

    // MARK: - Shelves

    @Test func shelvesReachHalfTheirGainAtTheCornerAndFullGainBeyond() {
        let low = Biquad(kind: .lowShelf, frequency: 200, gain: 6, q: 0.7, sampleRate: sampleRate)
        #expect(low.magnitudeDB(at: 200, sampleRate: sampleRate).isClose(to: 3, within: 0.2))
        #expect(low.magnitudeDB(at: 20, sampleRate: sampleRate).isClose(to: 6, within: 0.3))
        #expect(low.magnitudeDB(at: 10_000, sampleRate: sampleRate).isClose(to: 0, within: 0.2))

        let high = Biquad(
            kind: .highShelf, frequency: 4_000, gain: -6, q: 0.7, sampleRate: sampleRate)
        #expect(high.magnitudeDB(at: 4_000, sampleRate: sampleRate).isClose(to: -3, within: 0.2))
        #expect(high.magnitudeDB(at: 18_000, sampleRate: sampleRate).isClose(to: -6, within: 0.5))
        #expect(high.magnitudeDB(at: 100, sampleRate: sampleRate).isClose(to: 0, within: 0.2))
    }

    // MARK: - Pass filters

    @Test func passFiltersAreMinusThreeAtTheCornerAndCutBeyond() {
        let highPass = Biquad(
            kind: .highPass, frequency: 100, gain: 0, q: 0.707, sampleRate: sampleRate)
        #expect(highPass.magnitudeDB(at: 100, sampleRate: sampleRate).isClose(to: -3, within: 0.15))
        #expect(highPass.magnitudeDB(at: 25, sampleRate: sampleRate) < -20)
        #expect(highPass.magnitudeDB(at: 5_000, sampleRate: sampleRate).isClose(to: 0, within: 0.1))

        let lowPass = Biquad(
            kind: .lowPass, frequency: 5_000, gain: 0, q: 0.707, sampleRate: sampleRate)
        #expect(
            lowPass.magnitudeDB(at: 5_000, sampleRate: sampleRate).isClose(to: -3, within: 0.15))
        #expect(lowPass.magnitudeDB(at: 20_000, sampleRate: sampleRate) < -20)
        #expect(lowPass.magnitudeDB(at: 100, sampleRate: sampleRate).isClose(to: 0, within: 0.1))
    }

    /// A pass filter has no gain parameter, so the negligible-gain shortcut that
    /// makes an untouched band free must not apply to it — a 0 dB high pass is
    /// still very much doing something.
    @Test func passFiltersIgnoreGainWhenDecidingIfTheyAreActive() {
        #expect(Biquad.isActive(kind: .highPass, frequency: 100, gain: 0, sampleRate: sampleRate))
        #expect(Biquad.isActive(kind: .lowPass, frequency: 5_000, gain: 0, sampleRate: sampleRate))
        #expect(!Biquad.isActive(kind: .bell, frequency: 1_000, gain: 0, sampleRate: sampleRate))

        #expect(
            Biquad(kind: .highPass, frequency: 100, gain: 0, q: 0.707, sampleRate: sampleRate)
                != .identity)
    }

    /// The plot asks a different question from the processor: not "is this
    /// audible" but "can this be rendered at all". A band added a moment ago
    /// sits at 0 dB, and drawing it dimmed would say it is off when it is only
    /// flat.
    @Test func flatBandIsRealisableEvenThoughItIsNotActive() {
        #expect(Biquad.isRealisable(frequency: 1_000, sampleRate: sampleRate))
        #expect(!Biquad.isActive(kind: .bell, frequency: 1_000, gain: 0, sampleRate: sampleRate))
    }

    @Test func frequenciesOutsideTheRenderableRangeAreNotRealisable() {
        // 0.47 × 48 000 = 22 560 Hz.
        #expect(!Biquad.isRealisable(frequency: 23_000, sampleRate: sampleRate))
        #expect(!Biquad.isRealisable(frequency: 5, sampleRate: sampleRate))
        #expect(Biquad.isRealisable(frequency: 20_000, sampleRate: 44_100))
    }

    // MARK: - Identity guards

    @Test func negligibleGainIsIdentity() {
        #expect(bell(1_000, 0) == .identity)
    }

    @Test func disabledFilterIsIdentity() {
        let filter = EQFilter(frequency: 1_000, gain: 12, q: 1.41, isEnabled: false)
        #expect(Biquad(filter: filter, sampleRate: sampleRate) == .identity)
    }

    @Test func bandAtOrAboveNyquistCeilingIsIdentity() {
        // 0.47 × 48 000 = 22 560 Hz.
        #expect(bell(23_000, 6) == .identity)
        #expect(bell(20_000, 6) != .identity)
    }

    /// The ceiling exists so the top band survives at CD rate; if this ever
    /// regresses, 20 kHz silently stops doing anything on 44.1 kHz devices.
    @Test func topBandStaysActiveAt44100() {
        #expect(
            Biquad.isActive(kind: .bell, frequency: 20_000, gain: 6, sampleRate: 44_100),
            "the 20 kHz band must remain renderable at 44.1 kHz")
    }

    @Test func subsonicFrequencyIsIdentity() {
        #expect(bell(5, 6) == .identity)
    }

    @Test func identityPassesSignalThrough() {
        // b0 = 1 with every other coefficient zero is a pure pass-through.
        #expect(Biquad.identity.b0 == 1)
        #expect(Biquad.identity.b1 == 0)
        #expect(Biquad.identity.b2 == 0)
        #expect(Biquad.identity.a1 == 0)
        #expect(Biquad.identity.a2 == 0)
        #expect(
            Biquad.identity.magnitudeDB(at: 1_000, sampleRate: sampleRate).isClose(
                to: 0, within: 1e-12))
    }

    @Test func degenerateQIsClampedRatherThanExploding() {
        for kind in EQFilter.Kind.allCases {
            let filter = Biquad(kind: kind, frequency: 1_000, gain: 6, q: 0, sampleRate: sampleRate)
            #expect(filter.b0.isFinite, "\(kind)")
            #expect(filter.a2.isFinite, "\(kind)")
        }
    }
}
