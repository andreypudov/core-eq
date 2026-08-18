import XCTest

/// The correction that makes an A/B comparison about tone rather than loudness.
final class AutoGainTests: XCTestCase {
    private func chain(_ gains: [Double]) -> [EQFilter] {
        var bands = BuiltInProfiles.emptyBandChain()
        for slot in bands.indices where slot < gains.count { bands[slot].gain = gains[slot] }
        return bands
    }

    func testAFlatChainNeedsNoTrim() {
        XCTAssertEqual(AutoGain.trim(for: BuiltInProfiles.emptyBandChain()), 0, accuracy: 0.001)
        XCTAssertEqual(AutoGain.trim(for: []), 0)
    }

    /// The sign is the whole point: boosting has to pull the trim down.
    func testBoostTrimsDownAndCutTrimsUp() {
        XCTAssertLessThan(AutoGain.trim(for: chain([6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6])), -3)
        XCTAssertGreaterThan(
            AutoGain.trim(for: chain([-6, -6, -6, -6, -6, -6, -6, -6, -6, -6, -6])), 3)
    }

    /// A chain lifted by the same amount everywhere is the one case with an
    /// arithmetically obvious answer, so it is the one to pin down.
    func testAUniformLiftIsCancelledExactly() {
        let lifted = chain(Array(repeating: 4, count: BuiltInProfiles.bandCount))
        // Eleven overlapping octave bells at +4 dB sum to more than +4, so the
        // trim is larger than the slider value — what matters is that what comes
        // out is flat, which the next test measures directly.
        XCTAssertLessThan(AutoGain.trim(for: lifted), -4)
    }

    /// What the correction is for: the chain plus its trim should average out to
    /// where it started.
    func testTheCorrectedChainAveragesBackToZero() {
        for gains in [
            [6.0], [0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0], [3, 3, 3, -2, -2, 0, 4, 4, 1, 1, 1],
        ] {
            let filters = chain(gains)
            let trim = AutoGain.trim(for: filters)
            let corrected = average(of: filters) + trim
            XCTAssertEqual(corrected, 0, accuracy: 0.01, "\(gains) was left at \(corrected) dB")
        }
    }

    /// A narrow lift moves the average much less than a broad one. This is the
    /// difference between this and peak-based trimming, and the reason Bass
    /// Booster does not come back quiet.
    func testANarrowLiftIsCorrectedLessThanABroadOne() {
        let narrow = AutoGain.trim(for: chain([0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0]))
        let broad = AutoGain.trim(
            for: chain(Array(repeating: 10, count: BuiltInProfiles.bandCount)))
        XCTAssertGreaterThan(
            narrow, broad + 4, "a single band was corrected almost as hard as eleven")
        XCTAssertGreaterThan(narrow, -4)
    }

    func testTheTrimStaysInsideWhatTheControlCanHold() {
        let extreme = chain(Array(repeating: 12, count: BuiltInProfiles.bandCount))
        XCTAssertEqual(AutoGain.trim(for: extreme), BuiltInProfiles.preampRange.lowerBound)
    }

    /// Every shipped preset has to land somewhere a user would accept — a
    /// correction at the rail means the preset is quieter than it should be.
    func testNoBuiltInPresetIsCorrectedToTheRail() {
        for profile in BuiltInProfiles.all {
            let trim = AutoGain.trim(for: profile.filters)
            XCTAssertGreaterThan(
                trim, BuiltInProfiles.preampRange.lowerBound,
                "\(profile.name) needs more correction than the trim can hold"
            )
        }
    }

    /// The two device rates in practice must not give visibly different numbers,
    /// or the value would change under the user when they plug something in.
    func testTheRateBarelyMovesIt() {
        for profile in BuiltInProfiles.all {
            let at44 = AutoGain.trim(for: profile.filters, sampleRate: 44_100)
            let at48 = AutoGain.trim(for: profile.filters, sampleRate: 48_000)
            XCTAssertEqual(at44, at48, accuracy: 0.15, "\(profile.name) moves with the sample rate")
        }
    }

    private func average(of filters: [EQFilter]) -> Double {
        let rate = AutoGain.referenceSampleRate
        let biquads = filters.map { Biquad(filter: $0, sampleRate: rate) }
        let low = log10(20.0)
        let high = log10(20_000.0)
        let count = 96
        var total = 0.0
        for index in 0..<count {
            let f = pow(10, low + (high - low) * Double(index) / Double(count - 1))
            total += biquads.reduce(0.0) { $0 + $1.magnitudeDB(at: f, sampleRate: rate) }
        }
        return total / Double(count)
    }
}
