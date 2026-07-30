import XCTest

/// The filter math is shared by the audio path and the response curve, so these
/// tests are what keeps the drawn curve honest about what you hear.
final class PeakingFilterTests: XCTestCase {
    private let sampleRate = 48_000.0

    // MARK: - The defining property

    /// A peaking filter's magnitude at its own centre frequency is exactly its
    /// gain. Everything else in the app leans on this: it is why the band
    /// handles line up with the sliders, and why subtracting a band's gain from
    /// the composite yields its neighbours' contribution.
    func testMagnitudeAtCentreFrequencyEqualsGain() {
        for gain in [-12.0, -6.0, -0.5, 0.5, 3.0, 6.0, 12.0] {
            for frequency in [32.0, 250.0, 1_000.0, 8_000.0, 16_000.0] {
                let filter = PeakingFilter(
                    frequency: frequency, gain: gain, q: 1.41, sampleRate: sampleRate
                )
                XCTAssertEqual(
                    filter.magnitudeDB(at: frequency, sampleRate: sampleRate), gain,
                    accuracy: 0.001,
                    "\(gain) dB at \(frequency) Hz"
                )
            }
        }
    }

    func testResponseIsFlatFarFromCentreFrequency() {
        let filter = PeakingFilter(frequency: 1_000, gain: 12, q: 1.41, sampleRate: sampleRate)
        XCTAssertEqual(filter.magnitudeDB(at: 20, sampleRate: sampleRate), 0, accuracy: 0.2)
        XCTAssertEqual(filter.magnitudeDB(at: 20_000, sampleRate: sampleRate), 0, accuracy: 0.2)
    }

    func testHigherQNarrowsTheBell() {
        let wide = PeakingFilter(frequency: 1_000, gain: 12, q: 0.7, sampleRate: sampleRate)
        let narrow = PeakingFilter(frequency: 1_000, gain: 12, q: 4.0, sampleRate: sampleRate)

        // An octave away the wide filter should still be lifting appreciably
        // more than the narrow one.
        let wideAtOctave = wide.magnitudeDB(at: 2_000, sampleRate: sampleRate)
        let narrowAtOctave = narrow.magnitudeDB(at: 2_000, sampleRate: sampleRate)
        XCTAssertGreaterThan(wideAtOctave, narrowAtOctave)
    }

    func testBoostAndCutAreMirrored() {
        let boost = PeakingFilter(frequency: 1_000, gain: 6, q: 1.41, sampleRate: sampleRate)
        let cut = PeakingFilter(frequency: 1_000, gain: -6, q: 1.41, sampleRate: sampleRate)
        for probe in [500.0, 1_000.0, 2_000.0] {
            XCTAssertEqual(
                boost.magnitudeDB(at: probe, sampleRate: sampleRate),
                -cut.magnitudeDB(at: probe, sampleRate: sampleRate),
                accuracy: 0.001
            )
        }
    }

    // MARK: - Identity guards

    func testNegligibleGainIsIdentity() {
        let filter = PeakingFilter(frequency: 1_000, gain: 0, q: 1.41, sampleRate: sampleRate)
        XCTAssertEqual(filter, .identity)
    }

    func testBandAtOrAboveNyquistCeilingIsIdentity() {
        // 0.47 × 48 000 = 22 560 Hz.
        let above = PeakingFilter(frequency: 23_000, gain: 6, q: 1.41, sampleRate: sampleRate)
        XCTAssertEqual(above, .identity)

        let below = PeakingFilter(frequency: 20_000, gain: 6, q: 1.41, sampleRate: sampleRate)
        XCTAssertNotEqual(below, .identity)
    }

    /// The ceiling exists so the top band survives at CD rate; if this ever
    /// regresses, 20 kHz silently stops doing anything on 44.1 kHz devices.
    func testTopBandStaysActiveAt44100() {
        XCTAssertTrue(
            PeakingFilter.isActive(frequency: 20_000, gain: 6, sampleRate: 44_100),
            "the 20 kHz band must remain renderable at 44.1 kHz"
        )
    }

    func testSubsonicFrequencyIsIdentity() {
        XCTAssertEqual(
            PeakingFilter(frequency: 5, gain: 6, q: 1.41, sampleRate: sampleRate), .identity
        )
    }

    func testIdentityPassesSignalThrough() {
        // b0 = 1 with every other coefficient zero is a pure pass-through.
        XCTAssertEqual(PeakingFilter.identity.b0, 1)
        XCTAssertEqual(PeakingFilter.identity.b1, 0)
        XCTAssertEqual(PeakingFilter.identity.b2, 0)
        XCTAssertEqual(PeakingFilter.identity.a1, 0)
        XCTAssertEqual(PeakingFilter.identity.a2, 0)
        XCTAssertEqual(PeakingFilter.identity.magnitudeDB(at: 1_000, sampleRate: sampleRate), 0, accuracy: 1e-12)
    }

    func testDegenerateQIsClampedRatherThanExploding() {
        let filter = PeakingFilter(frequency: 1_000, gain: 6, q: 0, sampleRate: sampleRate)
        XCTAssertTrue(filter.b0.isFinite)
        XCTAssertTrue(filter.a2.isFinite)
    }
}
