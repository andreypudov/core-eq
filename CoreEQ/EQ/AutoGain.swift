import Foundation

/// The output trim that keeps a preset at the loudness it started from.
///
/// Louder sounds better. Boost four bands and the result wins any comparison
/// against the version without them — including A/B, which would otherwise be a
/// loudness test wearing a tone test's clothes. This is the correction that
/// takes the loudness back out so what is left to hear is the tone.
///
/// ## What it measures
///
/// The average of the chain's magnitude response over log-spaced frequencies:
/// equal weight per octave, which is pink weighting, which is roughly how music
/// distributes its energy. A preset that lifts one narrow band therefore gets a
/// small correction, and one that lifts everything gets a large one — which is
/// the behaviour a listener expects from a control called Auto.
///
/// ## What it deliberately does not do
///
/// It does not use the response's *peak* as a ceiling, which is what I first
/// proposed. Working it through: the peak is never smaller than the average, so
/// a peak ceiling is not a ceiling at all — it replaces the average in every
/// case and turns the correction into peak-based trimming. Bass Booster would
/// come back audibly quieter than the preset it was compared against, which is
/// precisely the failure the average exists to avoid.
///
/// Clipping is therefore not guaranteed away here. It cannot be: the headroom in
/// the incoming signal is unknown and unknowable — CoreEQ sees the mix after
/// every application has already set its own level. What this does is remove the
/// systematic part of the problem, which is a boosted chain asking for more
/// than it was given.
enum AutoGain {
    /// Where the response is sampled. The trim is a broadband average, so the
    /// exact rate barely moves it — the two common rates differ by hundredths of
    /// a decibel on every built-in preset — and pinning it keeps the number
    /// stable when a device changes underneath the user.
    static let referenceSampleRate = 48_000.0

    private static let lowestFrequency = 20.0
    private static let highestFrequency = 20_000.0

    /// Sample count across the band. Enough that a single narrow bell is
    /// represented by more than one point, few enough to run on every slider
    /// tick without thinking about it.
    private static let sampleCount = 96

    /// The trim, in dB, that cancels `filters`' average lift.
    ///
    /// Clamped to what the trim can actually hold: a chain asking for more
    /// correction than ±12 dB gets all the app has, and the number on screen
    /// stays a number the slider could have reached by hand.
    static func trim(for filters: [EQFilter], sampleRate: Double = referenceSampleRate) -> Double {
        guard !filters.isEmpty else { return 0 }

        let biquads = filters.map { Biquad(filter: $0, sampleRate: sampleRate) }
        guard biquads.contains(where: { $0 != .identity }) else { return 0 }

        let logLow = log10(lowestFrequency)
        let logHigh = log10(highestFrequency)
        var total = 0.0

        for index in 0..<sampleCount {
            let fraction = Double(index) / Double(sampleCount - 1)
            let frequency = pow(10, logLow + (logHigh - logLow) * fraction)
            total += biquads.reduce(0.0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
        }

        let average = total / Double(sampleCount)
        return (-average).clamped(to: BuiltInProfiles.preampRange)
    }
}
