import Foundation

/// Serializes CoreEQ equalizer profiles to standard EqualizerAPO `.txt` format
/// and native `.coreeq` JSON format.
enum ParametricEQSerializer {
    /// Serializes an `EQProfile` to the standard EqualizerAPO format.
    ///
    /// Example output:
    /// ```text
    /// Preamp: -2.5 dB
    /// Filter 1: ON PK Fc 32 Hz Gain 2.0 dB Q 1.41
    /// Filter 2: ON LSC Fc 90 Hz Gain 3.0 dB Q 0.70
    /// ```
    static func serializeToEqualizerAPO(_ profile: EQProfile) -> String {
        var lines: [String] = []

        // Write Preamp if non-zero
        if abs(profile.preamp) > 0.0001 {
            lines.append("Preamp: \(formatGain(profile.preamp)) dB")
        }

        var index = 1
        for filter in profile.filters {
            // Skip disabled or 0 dB identity band filters
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

        if lines.isEmpty {
            lines.append("Preamp: 0.0 dB")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Formatting Helpers

    /// AutoEQ's canonical EqualizerAPO precision: frequency whole Hz, gain one
    /// decimal, Q two decimals. These are presentation limits, not internal ones.
    static func formatFrequency(_ freq: Double) -> String {
        String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), freq)
    }

    /// Formats gain using AutoEQ's one decimal place.
    static func formatGain(_ gain: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), gain)
    }

    /// Formats Q factor with up to two decimals.
    static func formatQ(_ q: Double) -> String {
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), q)
    }

    /// Serializes an `EQProfile` into a native `.coreeq` JSON string.
    static func serializeToCoreEQJSON(_ profile: EQProfile) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ParametricEQParser.ParseError.invalidFormat
        }
        return string
    }
}
