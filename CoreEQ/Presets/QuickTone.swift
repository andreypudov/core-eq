import Foundation

/// The three tone controls exposed in the menu-bar Quick EQ. Each control is a
/// single -12…+12 dB value that spreads across the full band ladder using a
/// fixed weight curve, so moving one slider shapes several bands at once the
/// way a hardware bass/mid/treble knob would. The curves overlap gently in the
/// low-mids and high-mids to avoid audible seams between adjacent controls.
///
/// A band's gain is `profile.gain + bass·bassWeights + mid·midWeights +
/// treble·trebleWeights`, clamped to `BuiltInProfiles.gainRange`.
enum QuickTone {
    static let range = BuiltInProfiles.gainRange

    // Weight per band, aligned with `BuiltInProfiles.frequencies`
    // (32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k, 20k).
    static let bassWeights: [Double] = [
        1.00, 1.00, 0.80, 0.45, 0.15, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00,
    ]
    static let midWeights: [Double] = [
        0.00, 0.00, 0.20, 0.55, 0.90, 1.00, 0.90, 0.45, 0.10, 0.00, 0.00,
    ]
    static let trebleWeights: [Double] = [
        0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.20, 0.55, 0.85, 1.00, 1.00,
    ]

    /// Per-band gain offset produced by the three control values.
    static func offsets(bass: Double, mid: Double, treble: Double) -> [Double] {
        (0..<BuiltInProfiles.frequencies.count).map { i in
            bass * bassWeights[i] + mid * midWeights[i] + treble * trebleWeights[i]
        }
    }
}
