import Foundation

/// The numbers the axis, the sliders, the readouts, and the import sheet share,
/// in the user's locale: its digits (Arabic-Indic where the region uses them)
/// and its decimal separator (a comma in French or Russian). The signs do not
/// change with the language — a true minus sign, and "k" for kilohertz — and
/// the units are translated only where the language writes its own (see
/// `decibels`). Every view that shows these lays them out left to right, so
/// the sign stays in front of the number in a right-to-left language too.
enum BandFormat {
    /// The units, in the interface's language: "dB" and "Hz" in most, "дБ" and
    /// "Гц" where the language writes its own, as Apple's Russian does. One
    /// place, so a readout and the sentence about it agree.
    static var decibels: String {
        String(localized: "dB", comment: "Unit: decibels, after a gain such as “+4.0 dB”")
    }
    static var hertz: String {
        String(localized: "Hz", comment: "Unit: hertz, after a frequency such as “120 Hz”")
    }

    /// Axis and slider labels: "125", "1k", "16k". Shared so the plot's
    /// frequency axis and the slider captions can never disagree.
    static func frequency(_ frequency: Double, locale: Locale = .current) -> String {
        guard frequency >= 1_000 else { return whole(frequency, locale) }
        let kilohertz = frequency / 1_000
        return kilohertz == kilohertz.rounded()
            ? "\(whole(kilohertz, locale))k"
            : "\(tenths(kilohertz, locale))k"
    }

    /// Gain readouts: signed only when the sign carries information, so an
    /// untouched band reads "0.0 dB" rather than "+0.0 dB", and with a true
    /// minus sign, as every other gain in the app. The sign follows the value
    /// as shown, so −0.04 reads "0.0 dB", not "−0.0 dB".
    static func gain(_ gain: Double, locale: Locale = .current) -> String {
        let showsZero = (abs(gain) * 10).rounded(.toNearestOrEven) == 0
        let sign = showsZero ? "" : (gain > 0 ? "+" : "\u{2212}")
        return "\(sign)\(tenths(abs(gain), locale)) \(decibels)"
    }

    /// Scale marks without the unit, for a scale narrow enough that "dB" three
    /// times over crowds it and clear enough that it isn't needed.
    static func axisValue(_ gain: Double, locale: Locale = .current) -> String {
        "\(sign(gain))\(whole(abs(gain), locale))"
    }

    /// Whole-number dB scale marks, with a true minus sign rather than a hyphen.
    static func axisGain(_ gain: Double, locale: Locale = .current) -> String {
        "\(sign(gain))\(whole(abs(gain), locale)) \(decibels)"
    }

    private static func sign(_ value: Double) -> String {
        value > 0 ? "+" : (value < 0 ? "\u{2212}" : "")
    }

    /// Rounded half to even, as `%.1f` did: 4.25 shows as 4.2.
    private static func tenths(_ value: Double, _ locale: Locale) -> String {
        value.formatted(
            .number.precision(.fractionLength(1)).rounded(rule: .toNearestOrEven)
                .grouping(.never).locale(locale))
    }

    private static func whole(_ value: Double, _ locale: Locale) -> String {
        value.formatted(
            .number.precision(.fractionLength(0)).rounded(rule: .toNearestOrEven)
                .grouping(.never).locale(locale))
    }
}
