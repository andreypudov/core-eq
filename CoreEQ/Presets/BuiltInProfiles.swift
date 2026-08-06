import Foundation

/// The predefined profiles shipped with CoreEQ — the classic Apple/Spotify
/// preset set, mapped onto the band ladder below. Every built-in profile is
/// eleven ladder filters and nothing else, so selecting one clears any filters
/// the user added by hand and "Flat" means flat.
///
/// The ladder is the professional ISO octave graphic-EQ layout (32 Hz – 16 kHz)
/// extended with 20 kHz to cover the top of the audible range. Q of 1.41 gives
/// each band a one-octave bandwidth, matching the spacing.
enum BuiltInProfiles {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 20_000]
    static let defaultQ = 1.41
    static let gainRange: ClosedRange<Double> = -12...12

    /// Number of ladder slots, and so the number of sliders. Fixed by design:
    /// arbitrary centre frequencies live in free filters, not in a reshaped
    /// ladder.
    static var bandCount: Int { frequencies.count }

    /// How many filters the user may add on top of the ladder.
    ///
    /// A budget rather than a formality: each one is another pass over the
    /// buffer in `EQProcessor.processChannel`, and a listening application has
    /// no use for thirty of them.
    static let maxFreeFilters = 16

    /// Output trim range, matching the band range so the two read as one scale.
    static let preampRange: ClosedRange<Double> = -12...12

    /// Limits for the free filters' own parameters.
    static let filterFrequencyRange: ClosedRange<Double> = 20...20_000
    static let filterQRange: ClosedRange<Double> = 0.1...10

    static let all: [EQProfile] = [
        profile("Flat",           [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        profile("Acoustic",       [5, 5, 4, 1, 2, 1.5, 3.5, 4, 3.5, 2, 2]),
        profile("Bass Booster",   [5.5, 4.5, 3.5, 2.5, 1.25, 0, 0, 0, 0, 0, 0]),
        profile("Bass Reducer",   [-5.5, -4.5, -3.5, -2.5, -1.25, 0, 0, 0, 0, 0, 0]),
        profile("Classical",      [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 3.5, 3.5]),
        profile("Dance",          [3.5, 6.5, 5, 0, 2, 3.5, 5, 4.5, 3.5, 0, 0]),
        profile("Deep",           [5, 3.5, 1.5, 1, 3, 2.5, 1.5, -2, -3.5, -4.5, -4.5]),
        profile("Electronic",     [4.5, 4, 1.5, 0, -2, 2, 1, 1.5, 4, 4.5, 4.5]),
        profile("Hip-Hop",        [5, 4, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3, 3]),
        profile("Jazz",           [4, 3, 1.5, 2, -1.5, -1.5, 0, 1.5, 3, 3.5, 3.5]),
        profile("Latin",          [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5, 4.5]),
        profile("Loudness",       [6, 4, 0, 0, -2, 0, -1, -4.5, 5, 1, 1]),
        profile("Lounge",         [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1, 1]),
        profile("Piano",          [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5, 3.5]),
        profile("Pop",            [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5, -1.5]),
        profile("R&B",            [3, 7, 5.5, 1.5, -3, -1.5, 2, 2.5, 3, 3.5, 3.5]),
        profile("Rock",           [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5, 4.5]),
        profile("Small Speakers", [5.5, 4.5, 3.5, 2.5, 1.25, 0, -1.25, -2.5, -3.5, -4.5, -4.5]),
        profile("Spoken Word",    [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 5, 4.5, 2.5, 0, 0]),
        profile("Treble Booster", [0, 0, 0, 0, 0, 1.25, 2.5, 3.5, 4.5, 5.5, 5.5]),
        profile("Treble Reducer", [0, 0, 0, 0, 0, -1.25, -2.5, -3.5, -4.5, -5.5, -5.5]),
        profile("Vocal Booster",  [-1.5, -3, -3, 1.5, 3.5, 3.5, 3, 1.5, 0, -1.5, -1.5]),
    ]

    static let defaultProfileName = "Flat"

    /// A chain of eleven ladder filters at 0 dB — the shape every preset starts
    /// from, and what an untouched equalizer is.
    static func emptyBandChain() -> [EQFilter] {
        (0..<bandCount).map { EQFilter.band(slot: $0, gain: 0) }
    }

    private static func profile(_ name: String, _ gains: [Double]) -> EQProfile {
        assert(gains.count == frequencies.count)
        return EQProfile(
            name: name,
            filters: gains.enumerated().map { EQFilter.band(slot: $0, gain: $1) },
            isBuiltIn: true
        )
    }
}
