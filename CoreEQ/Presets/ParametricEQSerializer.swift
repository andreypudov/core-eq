import Foundation

/// Serializes CoreEQ equalizer profiles to standard EqualizerAPO `.txt` format
/// and native `.coreeq` JSON format.
enum ParametricEQSerializer {
    /// Serializes an `EQProfile` to the standard EqualizerAPO format.
    ///
    /// Example output:
    /// ```text
    /// Preamp: -2.5 dB
    /// Filter 1: ON PK Fc 32.0 Hz Gain 2.0 dB Q 1.41
    /// Filter 2: ON LSC Fc 90.0 Hz Gain 3.0 dB Q 0.70
    /// ```
    static func serializeToEqualizerAPO(_ profile: EQProfile) -> String {
        var lines: [String] = []

        // Write Preamp if non-zero
        if abs(profile.preamp) > 0.0001 {
            lines.append("Preamp: \(formatGain(profile.preamp)) dB")
        }

        var index = 1
        for filter in profile.filters {
            // A ladder band at 0 dB is identity, so it is left out. Disabled
            // filters are kept, written as OFF, so they come back disabled.
            if filter.isBand && abs(filter.gain) < 0.001 {
                continue
            }

            let status = filter.isEnabled ? "ON" : "OFF"
            let kindStr: String
            switch filter.kind {
            case .bell:
                kindStr = "PK"
            case .lowShelf:
                kindStr = "LSC"
            case .highShelf:
                kindStr = "HSC"
            case .highPass:
                kindStr = "HP"
            case .lowPass:
                kindStr = "LP"
            }

            let freqStr = formatFrequency(filter.frequency)
            let qStr = formatQ(filter.q)

            if filter.kind.usesGain {
                let gainStr = formatGain(filter.gain)
                lines.append(
                    "Filter \(index): \(status) \(kindStr) Fc \(freqStr) Hz Gain \(gainStr) dB Q \(qStr)"
                )
            } else {
                lines.append(
                    "Filter \(index): \(status) \(kindStr) Fc \(freqStr) Hz Q \(qStr)"
                )
            }
            index += 1
        }

        // Flat still writes a line: an empty file is not a preset, and the
        // parser takes a Preamp line alone as one.
        if lines.isEmpty {
            lines.append("Preamp: 0.0 dB")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Formatting Helpers

    /// Every number is written with as many decimals as it needs, up to four,
    /// so what CoreEQ writes reads back as the same number.
    ///
    /// AutoEQ writes one decimal, and one decimal is what this used to write —
    /// which turned a built-in's 1.75 dB into 1.8 and an imported 74.3 Hz
    /// into 74 on the way back in. The minimum keeps AutoEQ's look for the
    /// values it has: "2.0", "105.0", "0.70".
    static func formatFrequency(_ freq: Double) -> String {
        format(freq, minimumDecimals: 1)
    }

    static func formatGain(_ gain: Double) -> String {
        format(gain, minimumDecimals: 1)
    }

    static func formatQ(_ q: Double) -> String {
        format(q, minimumDecimals: 2)
    }

    private static func format(_ value: Double, minimumDecimals: Int) -> String {
        var text = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        guard let point = text.firstIndex(of: ".") else { return text }
        let shortest = text.index(point, offsetBy: minimumDecimals + 1)
        while text.endIndex > shortest, text.last == "0" { text.removeLast() }
        // A value that rounds to zero keeps no sign: "-0.0" reads as a cut.
        return text.hasPrefix("-") && Double(text) == 0 ? String(text.dropFirst()) : text
    }

    /// Serializes an `EQProfile` into a native `.coreeq` JSON string.
    static func serializeToCoreEQJSON(_ profile: EQProfile) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // `JSONEncoder` writes UTF-8, so decoding it back cannot fail.
        return String(decoding: try encoder.encode(profile), as: UTF8.self)
    }
}
