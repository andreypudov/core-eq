import Foundation

/// Turns AutoEQ's computed filters into a CoreEQ `EQProfile`.
///
/// Every path goes through `ParametricEQParser.parse`, so a profile built from
/// the API is normalized, clamped, and trimmed exactly like one imported from a
/// file — including the ladder-band recovery and the free-filter budget.
enum AutoEQProfileBuilder {
    /// Builds a profile from AutoEQ's JSON equalization.
    ///
    /// The filters are rendered to EqualizerAPO text with invariant formatting
    /// and parsed back, which is what makes the result indistinguishable from an
    /// imported preset. Filter types CoreEQ does not model are skipped; if that
    /// leaves nothing, the whole profile is rejected rather than shown empty.
    ///
    /// - Throws: `AutoEQError.unsupportedFilter` when every filter was skipped.
    static func makeProfile(model: String, equalized: AutoEQEqualizedProfile) throws -> EQProfile {
        var lines = ["Preamp: \(ParametricEQSerializer.formatGain(equalized.preamp)) dB"]
        var unknownTypes: [String] = []
        var index = 1

        for filter in equalized.filters {
            guard let code = apoCodes[filter.type.uppercased()] else {
                unknownTypes.append(filter.type)
                continue
            }
            let frequency = ParametricEQSerializer.formatFrequency(filter.fc)
            let gain = ParametricEQSerializer.formatGain(filter.gain)
            let q = ParametricEQSerializer.formatQ(filter.q)
            lines.append(
                "Filter \(index): ON \(code) Fc \(frequency) Hz Gain \(gain) dB Q \(q)")
            index += 1
        }

        guard index > 1 else {
            throw AutoEQError.unsupportedFilter(unknownTypes.joined(separator: ", "))
        }

        return try makeProfile(model: model, parametricEQText: lines.joined(separator: "\n") + "\n")
    }

    /// Builds a profile from pre-computed EqualizerAPO text, named for the model.
    static func makeProfile(model: String, parametricEQText: String) throws -> EQProfile {
        let parsed = try ParametricEQParser.parse(text: parametricEQText, defaultName: model)
        return EQProfile(
            name: parsed.name,
            filters: parsed.filters,
            preamp: parsed.preamp,
            autoGain: parsed.autoGain,
            isBuiltIn: false)
    }

    /// Builds a profile from the text AutoEQ publishes for variants that cannot
    /// be sent to `/equalize`. Named for the model; `source` and `form` are
    /// accepted so callers can hand over everything they fetched without
    /// reshaping it, but the text is the whole profile.
    static func makeFallbackProfile(
        model: String, source: String, form: String, parametricEQText: String
    ) throws -> EQProfile {
        _ = (source, form)
        return try makeProfile(model: model, parametricEQText: parametricEQText)
    }

    /// AutoEQ filter type to EqualizerAPO code. Anything absent is skipped.
    private static let apoCodes: [String: String] = [
        "PEAKING": "PK",
        "PEAK": "PK",
        "PK": "PK",
        "LOW_SHELF": "LSC",
        "LOWSHELF": "LSC",
        "LOW SHELF": "LSC",
        "LS": "LSC",
        "LSC": "LSC",
        "HIGH_SHELF": "HSC",
        "HIGHSHELF": "HSC",
        "HIGH SHELF": "HSC",
        "HS": "HSC",
        "HSC": "HSC",
        "LOW_PASS": "LP",
        "LOWPASS": "LP",
        "LOW PASS": "LP",
        "LP": "LP",
        "HIGH_PASS": "HP",
        "HIGHPASS": "HP",
        "HIGH PASS": "HP",
        "HP": "HP",
    ]
}
