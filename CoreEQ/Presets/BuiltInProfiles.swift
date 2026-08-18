// swift-format-ignore-file
//
// The preset table below is aligned by hand so the eleven gains line up in
// columns: that is how one preset is compared with another by eye, and it is
// the reason this file reads as a table rather than a list of calls. The
// formatter collapses that alignment, so this one file opts out.

import Foundation

/// The predefined profiles shipped with CoreEQ — the classic Apple/Spotify
/// preset set, mapped onto the band ladder below. Selecting one replaces the
/// whole chain, so it clears any filters the user added by hand and "Flat"
/// means flat.
///
/// Most carry a shelf or two alongside the ladder, under one rule:
///
/// > **The ladder carries the preset. A filter only does what the ladder
/// > cannot: hold a shape past its ends, place energy between rungs, or use a
/// > bandwidth other than one octave. Strip every filter from a preset and the
/// > curve must still be recognisably that preset.**
///
/// The rule exists to keep the Graphic tab honest. If a preset's shape lived in
/// filters, its eleven sliders would sit flat under a curve that is anything
/// but, and dragging one would move the sound relative to a baseline the user
/// cannot see. Filters extend the sliders; they never replace them, and
/// `BuiltInProfilesTests` holds them to it.
///
/// What the ladder cannot do, measured rather than assumed:
///
/// - **Below its lowest rung it can only fall away.** A bell at 32 Hz is a bell:
///   Bass Booster reached +6.5 dB at 32 Hz and only +2.25 dB at 20 Hz — a third
///   of the advertised lift in the octave you feel.
/// - **Its top two rungs depend on the output device.** 16 kHz and 20 kHz sit
///   close enough to Nyquist that the sample rate reshapes them: Treble Booster
///   was +5.5 dB at 19 kHz on a 48 kHz device and +3.3 dB on a 44.1 kHz one.
/// - **Octave-spaced bells scallop between rungs.** Treble Booster sagged to
///   +3.2 dB at 12 kHz between its +6.7 dB neighbours, and no ladder gain can
///   fill a gap that lies between two sliders.
///
/// The ladder is the professional ISO octave graphic-EQ layout (32 Hz – 16 kHz)
/// extended with 20 kHz to cover the top of the audible range. Q of 1.41 gives
/// each band a one-octave bandwidth, matching the spacing. Every rung is a
/// bell, the ends included — `EQFilter.band(slot:gain:isEnabled:)` records what
/// happened when they were tried as shelves.
enum BuiltInProfiles {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 20_000]

    /// Q of the ladder's bells: one octave of bandwidth, matching the spacing.
    static let defaultQ = 1.41

    /// Q of the shelves the presets reach for. For a shelf this is the knee,
    /// and 0.7 is the gentle slope that arrives at its plateau without a bump
    /// at the corner.
    static let shelfQ = 0.7

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
        // Two things the rungs cannot do. A presence lift at 2.8 kHz, where an
        // acoustic guitar's pick and body live — it falls between the 2 k and
        // 4 k rungs, which could only reach it by lifting both and sagging in
        // between. And the shelf every bass-lifting preset here carries, which
        // holds the low end through the bottom octave: 39% of the 45 Hz level
        // survived to 20 Hz before, 76% now.
        profile("Acoustic",       [1.75, 1.75, 4, 1, 2, 1.5, 2.5, 3, 3.5, 2, 2],
                [EQFilter(kind: .bell, frequency: 2_800, gain: 2, q: 1.2, colorIndex: 0),
                 EQFilter(kind: .lowShelf, frequency: 120, gain: 3.25, q: BuiltInProfiles.shelfQ, colorIndex: 1)]),
        // The shelf holds the boost through the bottom octave instead of
        // rolling off below the lowest rung: +5.2 dB at 20 Hz where the ladder
        // alone managed +2.25. The rungs come down so the preset is not louder
        // than it was where it already worked.
        profile("Bass Booster",   [3, 2.5, 2, 1.5, 0.75, 0, 0, 0, 0, 0, 0],
                [EQFilter(kind: .lowShelf, frequency: 120, gain: 4, q: BuiltInProfiles.shelfQ, colorIndex: 0)]),
        profile("Bass Reducer",   [-2.75, -2.25, -3.5, -2.5, -1.25, 0, 0, 0, 0, 0, 0],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: -3.25, q: BuiltInProfiles.shelfQ, colorIndex: 0)]),
        profile("Classical",      [1.75, 1.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 1.5, 1.5],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 3, q: BuiltInProfiles.shelfQ, colorIndex: 0),
                 EQFilter(kind: .highShelf, frequency: 10_000, gain: 2, q: BuiltInProfiles.shelfQ, colorIndex: 1)]),
        profile("Dance",          [1.75, 3.25, 5, 0, 2, 3.5, 5, 4.5, 3.5, 0, 0],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 3.75, q: BuiltInProfiles.shelfQ, colorIndex: 0)]),
        profile("Deep",           [3, 2, 1.5, 1, 3, 2.5, 1.5, -2, -3.5, -1.75, -1.75],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 2.5, q: BuiltInProfiles.shelfQ, colorIndex: 0),
                 EQFilter(kind: .highShelf, frequency: 10_000, gain: -2.25, q: BuiltInProfiles.shelfQ, colorIndex: 1)]),
        profile("Electronic",     [2.25, 2, 1.5, 0, -2, 2, 1, 1.5, 4, 1.75, 1.75],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 2.5, q: BuiltInProfiles.shelfQ, colorIndex: 0),
                 EQFilter(kind: .highShelf, frequency: 10_000, gain: 3, q: BuiltInProfiles.shelfQ, colorIndex: 1)]),
        profile("Hip-Hop",        [2.5, 2, 1.5, 3, -1, -1, 1.5, -0.5, 2, 1, 1],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 3, q: BuiltInProfiles.shelfQ, colorIndex: 0),
                 EQFilter(kind: .highShelf, frequency: 9_000, gain: 1.25, q: BuiltInProfiles.shelfQ, colorIndex: 1)]),
        profile("Jazz",           [1.5, 1.25, 1.5, 2, -1.5, -1.5, 0, 1.5, 3, 1.5, 1.5],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 2.5, q: BuiltInProfiles.shelfQ, colorIndex: 0),
                 EQFilter(kind: .highShelf, frequency: 10_000, gain: 2, q: BuiltInProfiles.shelfQ, colorIndex: 1)]),
        profile("Latin",          [2.25, 1.5, 0, 0, -1.5, -1.5, -1.5, 0, 3, 1.25, 1.25],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 2.25, q: BuiltInProfiles.shelfQ, colorIndex: 0),
                 EQFilter(kind: .highShelf, frequency: 10_000, gain: 2, q: BuiltInProfiles.shelfQ, colorIndex: 1)]),
        profile("Loudness",       [3.5, 2.5, 0, 0, -2, 0, -1, -4.5, 5, 1, 1],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 2.25, q: BuiltInProfiles.shelfQ, colorIndex: 0)]),
        profile("Lounge",         [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1, 1]),
        profile("Piano",          [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 1.5, 1.5],
                [EQFilter(kind: .highShelf, frequency: 10_000, gain: 2.5, q: BuiltInProfiles.shelfQ, colorIndex: 0)]),
        profile("Pop",            [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5, -1.5]),
        profile("R&B",            [1.75, 3.75, 5.5, 1.5, -3, -1.5, 2, 2.5, 3, 1.5, 1.5],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 4, q: BuiltInProfiles.shelfQ, colorIndex: 0),
                 EQFilter(kind: .highShelf, frequency: 10_000, gain: 2.25, q: BuiltInProfiles.shelfQ, colorIndex: 1)]),
        profile("Rock",           [2, 1.5, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 1.75, 1.75],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 3.5, q: BuiltInProfiles.shelfQ, colorIndex: 0),
                 EQFilter(kind: .highShelf, frequency: 10_000, gain: 2.5, q: BuiltInProfiles.shelfQ, colorIndex: 1)]),
        profile("Small Speakers", [2.75, 2.25, 3.5, 2.5, 1.25, 0, -1.25, -2.5, -3.5, -1.75, -1.75],
                [EQFilter(kind: .lowShelf, frequency: 90, gain: 3.5, q: BuiltInProfiles.shelfQ, colorIndex: 0),
                 EQFilter(kind: .highShelf, frequency: 10_000, gain: -2.5, q: BuiltInProfiles.shelfQ, colorIndex: 1)]),
        profile("Spoken Word",    [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 5, 4.5, 2.5, 0, 0]),
        // The shelf takes over the top octave, where the rungs are least
        // trustworthy: the 12 kHz sag between them halves, and the difference
        // between a 44.1 kHz and a 48 kHz device at 19 kHz drops from 2.2 dB to
        // 1.0. The sliders still rise through the treble and taper at the very
        // top — which is the truth about those two rungs.
        profile("Treble Booster", [0, 0, 0, 0, 0, 1.25, 2.5, 3.5, 4.5, 3.5, 2],
                [EQFilter(kind: .highShelf, frequency: 9_000, gain: 2, q: BuiltInProfiles.shelfQ, colorIndex: 0)]),
        profile("Treble Reducer", [0, 0, 0, 0, 0, -1.25, -2.5, -3.5, -4.5, -2.25, -2.25],
                [EQFilter(kind: .highShelf, frequency: 10_000, gain: -3.25, q: BuiltInProfiles.shelfQ, colorIndex: 0)]),
        profile("Vocal Booster",  [-1.5, -3, -3, 1.5, 3.5, 3.5, 3, 1.5, 0, -1.5, -1.5]),
    ]

    static let defaultProfileName = "Flat"

    /// A chain of eleven ladder filters at 0 dB — the shape every preset starts
    /// from, and what an untouched equalizer is.
    static func emptyBandChain() -> [EQFilter] {
        (0..<bandCount).map { EQFilter.band(slot: $0, gain: 0) }
    }

    /// - Parameter filters: what the ladder cannot express, if anything. Kept
    ///   to one or two: each is another pass over the buffer in
    ///   `EQProcessor.processChannel`, and each one a preset spends is one the
    ///   user cannot (`maxFreeFilters`).
    private static func profile(
        _ name: String,
        _ gains: [Double],
        _ filters: [EQFilter] = []
    ) -> EQProfile {
        assert(gains.count == frequencies.count)
        return EQProfile(
            name: name,
            filters: gains.enumerated().map { EQFilter.band(slot: $0, gain: $1) } + filters,
            isBuiltIn: true
        )
    }
}
