import Foundation

enum BandFormat {
    /// Axis and slider labels: "125", "1k", "16k". Shared so the plot's
    /// frequency axis and the slider captions can never disagree.
    static func frequency(_ frequency: Double) -> String {
        guard frequency >= 1_000 else { return "\(Int(frequency))" }
        let kilohertz = frequency / 1_000
        return kilohertz == kilohertz.rounded()
            ? "\(Int(kilohertz))k"
            : String(format: "%.1fk", kilohertz)
    }

    /// Gain readouts: signed only when the sign carries information, so an
    /// untouched band reads "0.0 dB" rather than "+0.0 dB", and with a true
    /// minus sign, as every other gain in the app. The sign follows the value
    /// as shown, so −0.04 reads "0.0 dB", not "−0.0 dB".
    static func gain(_ gain: Double) -> String {
        let magnitude = String(format: "%.1f", abs(gain))
        let sign = magnitude == "0.0" ? "" : (gain > 0 ? "+" : "\u{2212}")
        return "\(sign)\(magnitude) dB"
    }

    /// Scale marks without the unit, for a scale narrow enough that "dB" three
    /// times over crowds it and clear enough that it isn't needed.
    static func axisValue(_ gain: Double) -> String {
        String(format: "%@%.0f", gain > 0 ? "+" : (gain < 0 ? "\u{2212}" : ""), abs(gain))
    }

    /// Whole-number dB scale marks, with a true minus sign rather than a hyphen.
    static func axisGain(_ gain: Double) -> String {
        String(format: "%@%.0f dB", gain > 0 ? "+" : (gain < 0 ? "\u{2212}" : ""), abs(gain))
    }
}
