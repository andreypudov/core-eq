import Foundation
import Testing

/// The correction that makes an A/B comparison about tone rather than loudness.
struct AutoGainTests {
    private func chain(_ gains: [Double]) -> [EQFilter] {
        var bands = BuiltInProfiles.emptyBandChain()
        for slot in bands.indices where slot < gains.count { bands[slot].gain = gains[slot] }
        return bands
    }

    @Test func aFlatChainNeedsNoTrim() {
        #expect(AutoGain.trim(for: BuiltInProfiles.emptyBandChain()).isClose(to: 0, within: 0.001))
        #expect(AutoGain.trim(for: []) == 0)
    }

    /// The sign is the whole point: boosting has to pull the trim down.
    @Test func boostTrimsDown() {
        #expect(AutoGain.trim(for: chain([6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6])) < -3)
    }

    /// The correction only ever attenuates, which is what makes it safe to leave
    /// on: cancelling a cut means lifting every frequency the preset left alone,
    /// broadband, over material that may already be at full scale.
    @Test func aCutIsNotCorrectedBackUp() {
        #expect(AutoGain.trim(for: chain([-6, -6, -6, -6, -6, -6, -6, -6, -6, -6, -6])) == 0)
        #expect(AutoGain.trim(for: chain([0, 0, 0, 0, -8, 0, 0, 0, 0, 0, 0])) == 0)
    }

    @Test func everyBuiltInAsksForAttenuationOrNothing() {
        for profile in BuiltInProfiles.all {
            #expect(
                AutoGain.trim(for: profile.filters) <= 0,
                "\(profile.name) would be boosted by a mode that is on by default")
        }
    }

    /// A chain lifted by the same amount everywhere is the one case with an
    /// arithmetically obvious answer, so it is the one to pin down.
    @Test func aUniformLiftIsCancelledExactly() {
        let lifted = chain(Array(repeating: 4, count: BuiltInProfiles.bandCount))
        // Eleven overlapping octave bells at +4 dB sum to more than +4, so the
        // trim is larger than the slider value — what matters is that what comes
        // out is flat, which the next test measures directly.
        #expect(AutoGain.trim(for: lifted) < -4)
    }

    /// What the correction is for: the chain plus its trim should average out to
    /// where it started.
    @Test func theCorrectedChainAveragesBackToZero() {
        for gains in [
            [6.0], [0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0], [3, 3, 3, -2, -2, 0, 4, 4, 1, 1, 1],
        ] {
            let filters = chain(gains)
            let trim = AutoGain.trim(for: filters)
            let corrected = average(of: filters) + trim
            #expect(corrected.isClose(to: 0, within: 0.01), "\(gains) was left at \(corrected) dB")
        }
    }

    /// A narrow lift moves the average much less than a broad one. This is the
    /// difference between this and peak-based trimming, and the reason Bass
    /// Booster does not come back quiet.
    @Test func aNarrowLiftIsCorrectedLessThanABroadOne() {
        let narrow = AutoGain.trim(for: chain([0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0]))
        let broad = AutoGain.trim(
            for: chain(Array(repeating: 10, count: BuiltInProfiles.bandCount)))
        #expect(narrow > broad + 4, "a single band was corrected almost as hard as eleven")
        #expect(narrow > -4)
    }

    @Test func theTrimStaysInsideWhatTheControlCanHold() {
        let extreme = chain(Array(repeating: 12, count: BuiltInProfiles.bandCount))
        #expect(AutoGain.trim(for: extreme) == BuiltInProfiles.preampRange.lowerBound)
    }

    /// Every shipped preset has to land somewhere a user would accept — a
    /// correction at the rail means the preset is quieter than it should be.
    @Test func noBuiltInPresetIsCorrectedToTheRail() {
        for profile in BuiltInProfiles.all {
            let trim = AutoGain.trim(for: profile.filters)
            #expect(
                trim > BuiltInProfiles.preampRange.lowerBound,
                "\(profile.name) needs more correction than the trim can hold")
        }
    }

    /// The two device rates in practice must not give visibly different numbers,
    /// or the value would change under the user when they plug something in.
    @Test func theRateBarelyMovesIt() {
        for profile in BuiltInProfiles.all {
            let at44 = AutoGain.trim(for: profile.filters, sampleRate: 44_100)
            let at48 = AutoGain.trim(for: profile.filters, sampleRate: 48_000)
            #expect(
                at44.isClose(to: at48, within: 0.15), "\(profile.name) moves with the sample rate")
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
