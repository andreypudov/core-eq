import Foundation

/// A single equalizer band: a peaking filter centered on `frequency`.
struct EQBand: Codable, Equatable {
    var frequency: Double
    var gain: Double
    var q: Double

    init(frequency: Double, gain: Double, q: Double = BuiltInProfiles.defaultQ) {
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }
}

/// A named set of band parameters.
struct EQProfile: Codable, Equatable, Identifiable {
    var name: String
    var bands: [EQBand]

    var id: String { name }
}

/// The predefined profiles shipped with CoreEQ — the classic Apple/Spotify
/// preset set, mapped onto the band layout below. All profiles share the same
/// fixed center frequencies so switching between them only changes gains.
///
/// The layout is the professional ISO octave graphic-EQ ladder (32 Hz – 8 kHz)
/// extended with 15 kHz and 20 kHz to cover the full audible range. Q of 1.41
/// gives each peaking filter a one-octave bandwidth, matching the spacing.
enum BuiltInProfiles {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 15_000, 20_000]
    static let defaultQ = 1.41
    static let gainRange: ClosedRange<Double> = -12...12

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

    private static func profile(_ name: String, _ gains: [Double]) -> EQProfile {
        assert(gains.count == frequencies.count)
        return EQProfile(name: name, bands: zip(frequencies, gains).map { EQBand(frequency: $0, gain: $1) })
    }
}
