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

/// The predefined profiles shipped with CoreEQ. All profiles share the same
/// fixed center frequencies so switching between them only changes gains.
enum BuiltInProfiles {
    static let frequencies: [Double] = [60, 150, 400, 1_000, 2_500, 6_000, 12_000]
    static let defaultQ = 1.1
    static let gainRange: ClosedRange<Double> = -12...12

    static let all: [EQProfile] = [
        profile("Flat", [0, 0, 0, 0, 0, 0, 0]),
        profile("Bass Boost", [6, 4.5, 2, 0, 0, 0, 0]),
        profile("Treble Boost", [0, 0, 0, 0, 2, 4, 6]),
        profile("V-Shaped", [5, 3, 0, -1.5, 0, 3, 5]),
        profile("Voice / Podcast", [-2, -1, 1.5, 3, 2.5, 1, -1]),
        profile("Classical / Neutral", [1.5, 1, 0, -0.5, 0, 1, 1.5]),
    ]

    static let defaultProfileName = "Flat"

    private static func profile(_ name: String, _ gains: [Double]) -> EQProfile {
        EQProfile(name: name, bands: zip(frequencies, gains).map { EQBand(frequency: $0, gain: $1) })
    }
}
