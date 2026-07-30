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
