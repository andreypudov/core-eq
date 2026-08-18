import XCTest

/// The filter math is shared by the audio path and the response curve, so these
/// tests are what keeps the drawn curve honest about what you hear.
final class BiquadTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func bell(_ frequency: Double, _ gain: Double, q: Double = 1.41) -> Biquad {
        Biquad(kind: .bell, frequency: frequency, gain: gain, q: q, sampleRate: sampleRate)
    }

    // MARK: - The defining property

    /// A peaking filter's magnitude at its own centre frequency is exactly its
    /// gain. Everything else in the app leans on this: it is why the band
    /// handles line up with the sliders, and why subtracting a band's gain from
    /// the composite yields its neighbours' contribution.
    func testMagnitudeAtCentreFrequencyEqualsGain() {
        for gain in [-12.0, -6.0, -0.5, 0.5, 3.0, 6.0, 12.0] {
            for frequency in [32.0, 250.0, 1_000.0, 8_000.0, 16_000.0] {
                XCTAssertEqual(
                    bell(frequency, gain).magnitudeDB(at: frequency, sampleRate: sampleRate), gain,
                    accuracy: 0.001,
                    "\(gain) dB at \(frequency) Hz"
                )
            }
        }
    }

    func testResponseIsFlatFarFromCentreFrequency() {
        let filter = bell(1_000, 12)
        XCTAssertEqual(filter.magnitudeDB(at: 20, sampleRate: sampleRate), 0, accuracy: 0.2)
        XCTAssertEqual(filter.magnitudeDB(at: 20_000, sampleRate: sampleRate), 0, accuracy: 0.2)
    }

    func testHigherQNarrowsTheBell() {
        // An octave away the wide filter should still be lifting appreciably
        // more than the narrow one.
        XCTAssertGreaterThan(
            bell(1_000, 12, q: 0.7).magnitudeDB(at: 2_000, sampleRate: sampleRate),
            bell(1_000, 12, q: 4.0).magnitudeDB(at: 2_000, sampleRate: sampleRate)
        )
    }

    func testBoostAndCutAreMirrored() {
        let boost = bell(1_000, 6)
        let cut = bell(1_000, -6)
        for probe in [500.0, 1_000.0, 2_000.0] {
            XCTAssertEqual(
                boost.magnitudeDB(at: probe, sampleRate: sampleRate),
                -cut.magnitudeDB(at: probe, sampleRate: sampleRate),
                accuracy: 0.001
            )
        }
    }

    /// The property the whole layered-chain idea rests on: cascaded biquads
    /// multiply in magnitude, so their dB contributions add exactly. If this
    /// ever stopped holding, the composite curve would no longer be the sum of
    /// its parts, and the graph would be lying about what is being heard.
    func testChainMagnitudesAddInDecibels() {
        let filters = [bell(125, 3), bell(180, 2, q: 0.8), bell(4_000, -4, q: 2)]
        for probe in [60.0, 125.0, 180.0, 1_000.0, 4_000.0, 12_000.0] {
            let summed = filters.reduce(0.0) {
                $0 + $1.magnitudeDB(at: probe, sampleRate: sampleRate)
            }
            let product = filters.reduce(1.0) {
                $0 * pow(10.0, $1.magnitudeDB(at: probe, sampleRate: sampleRate) / 20.0)
            }
            XCTAssertEqual(summed, 20.0 * log10(product), accuracy: 1e-9, "at \(probe) Hz")
        }
    }

    // MARK: - Shelves

    func testShelvesReachHalfTheirGainAtTheCornerAndFullGainBeyond() {
        let low = Biquad(kind: .lowShelf, frequency: 200, gain: 6, q: 0.7, sampleRate: sampleRate)
        XCTAssertEqual(low.magnitudeDB(at: 200, sampleRate: sampleRate), 3, accuracy: 0.2)
        XCTAssertEqual(low.magnitudeDB(at: 20, sampleRate: sampleRate), 6, accuracy: 0.3)
        XCTAssertEqual(low.magnitudeDB(at: 10_000, sampleRate: sampleRate), 0, accuracy: 0.2)

        let high = Biquad(
            kind: .highShelf, frequency: 4_000, gain: -6, q: 0.7, sampleRate: sampleRate)
        XCTAssertEqual(high.magnitudeDB(at: 4_000, sampleRate: sampleRate), -3, accuracy: 0.2)
        XCTAssertEqual(high.magnitudeDB(at: 18_000, sampleRate: sampleRate), -6, accuracy: 0.5)
        XCTAssertEqual(high.magnitudeDB(at: 100, sampleRate: sampleRate), 0, accuracy: 0.2)
    }

    // MARK: - Pass filters

    func testPassFiltersAreMinusThreeAtTheCornerAndCutBeyond() {
        let highPass = Biquad(
            kind: .highPass, frequency: 100, gain: 0, q: 0.707, sampleRate: sampleRate)
        XCTAssertEqual(highPass.magnitudeDB(at: 100, sampleRate: sampleRate), -3, accuracy: 0.15)
        XCTAssertLessThan(highPass.magnitudeDB(at: 25, sampleRate: sampleRate), -20)
        XCTAssertEqual(highPass.magnitudeDB(at: 5_000, sampleRate: sampleRate), 0, accuracy: 0.1)

        let lowPass = Biquad(
            kind: .lowPass, frequency: 5_000, gain: 0, q: 0.707, sampleRate: sampleRate)
        XCTAssertEqual(lowPass.magnitudeDB(at: 5_000, sampleRate: sampleRate), -3, accuracy: 0.15)
        XCTAssertLessThan(lowPass.magnitudeDB(at: 20_000, sampleRate: sampleRate), -20)
        XCTAssertEqual(lowPass.magnitudeDB(at: 100, sampleRate: sampleRate), 0, accuracy: 0.1)
    }

    /// A pass filter has no gain parameter, so the negligible-gain shortcut that
    /// makes an untouched band free must not apply to it — a 0 dB high pass is
    /// still very much doing something.
    func testPassFiltersIgnoreGainWhenDecidingIfTheyAreActive() {
        XCTAssertTrue(
            Biquad.isActive(kind: .highPass, frequency: 100, gain: 0, sampleRate: sampleRate))
        XCTAssertTrue(
            Biquad.isActive(kind: .lowPass, frequency: 5_000, gain: 0, sampleRate: sampleRate))
        XCTAssertFalse(
            Biquad.isActive(kind: .bell, frequency: 1_000, gain: 0, sampleRate: sampleRate))

        XCTAssertNotEqual(
            Biquad(kind: .highPass, frequency: 100, gain: 0, q: 0.707, sampleRate: sampleRate),
            .identity
        )
    }

    /// The plot asks a different question from the processor: not "is this
    /// audible" but "can this be rendered at all". A band added a moment ago
    /// sits at 0 dB, and drawing it dimmed would say it is off when it is only
    /// flat.
    func testFlatBandIsRealisableEvenThoughItIsNotActive() {
        XCTAssertTrue(Biquad.isRealisable(frequency: 1_000, sampleRate: sampleRate))
        XCTAssertFalse(
            Biquad.isActive(kind: .bell, frequency: 1_000, gain: 0, sampleRate: sampleRate))
    }

    func testFrequenciesOutsideTheRenderableRangeAreNotRealisable() {
        // 0.47 × 48 000 = 22 560 Hz.
        XCTAssertFalse(Biquad.isRealisable(frequency: 23_000, sampleRate: sampleRate))
        XCTAssertFalse(Biquad.isRealisable(frequency: 5, sampleRate: sampleRate))
        XCTAssertTrue(Biquad.isRealisable(frequency: 20_000, sampleRate: 44_100))
    }

    // MARK: - Identity guards

    func testNegligibleGainIsIdentity() {
        XCTAssertEqual(bell(1_000, 0), .identity)
    }

    func testDisabledFilterIsIdentity() {
        let filter = EQFilter(frequency: 1_000, gain: 12, q: 1.41, isEnabled: false)
        XCTAssertEqual(Biquad(filter: filter, sampleRate: sampleRate), .identity)
    }

    func testBandAtOrAboveNyquistCeilingIsIdentity() {
        // 0.47 × 48 000 = 22 560 Hz.
        XCTAssertEqual(bell(23_000, 6), .identity)
        XCTAssertNotEqual(bell(20_000, 6), .identity)
    }

    /// The ceiling exists so the top band survives at CD rate; if this ever
    /// regresses, 20 kHz silently stops doing anything on 44.1 kHz devices.
    func testTopBandStaysActiveAt44100() {
        XCTAssertTrue(
            Biquad.isActive(kind: .bell, frequency: 20_000, gain: 6, sampleRate: 44_100),
            "the 20 kHz band must remain renderable at 44.1 kHz"
        )
    }

    func testSubsonicFrequencyIsIdentity() {
        XCTAssertEqual(bell(5, 6), .identity)
    }

    func testIdentityPassesSignalThrough() {
        // b0 = 1 with every other coefficient zero is a pure pass-through.
        XCTAssertEqual(Biquad.identity.b0, 1)
        XCTAssertEqual(Biquad.identity.b1, 0)
        XCTAssertEqual(Biquad.identity.b2, 0)
        XCTAssertEqual(Biquad.identity.a1, 0)
        XCTAssertEqual(Biquad.identity.a2, 0)
        XCTAssertEqual(
            Biquad.identity.magnitudeDB(at: 1_000, sampleRate: sampleRate), 0, accuracy: 1e-12)
    }

    func testDegenerateQIsClampedRatherThanExploding() {
        for kind in EQFilter.Kind.allCases {
            let filter = Biquad(kind: kind, frequency: 1_000, gain: 6, q: 0, sampleRate: sampleRate)
            XCTAssertTrue(filter.b0.isFinite, "\(kind)")
            XCTAssertTrue(filter.a2.isFinite, "\(kind)")
        }
    }
}
