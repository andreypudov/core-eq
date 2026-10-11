import Foundation

/// Turns AutoEq correction filters into a CoreEQ `ImportCandidates`.
///
/// Uses the shared import parser, so a published correction follows the same
/// disclosure path as any other import: representable values are kept exact,
/// and anything CoreEQ must change is reported rather than silently clamped or
/// rejected.
enum AutoEQProfileBuilder {
    /// Builds candidates from AutoEQ's JSON equalization.
    ///
    /// The filters are rendered to EqualizerAPO text with invariant formatting
    /// and parsed back, which is what makes the result indistinguishable from an
    /// imported preset. Filter types CoreEQ does not model are skipped; if that
    /// leaves nothing, the whole profile is rejected rather than shown empty.
    ///
    /// - Throws: `AutoEQError.unsupportedFilter` when every filter was skipped.
    static func makeProfile(
        model: String, equalized: AutoEQEqualizedProfile, sampleRate: Double = 44_100
    ) throws -> ImportCandidates {
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

        return try makeProfile(
            model: model, parametricEQText: lines.joined(separator: "\n") + "\n",
            sampleRate: sampleRate)
    }

    /// Builds candidates from pre-computed EqualizerAPO text, named for the
    /// model.
    ///
    /// No correction is rejected for being out of range: the parser's candidates
    /// carry the exact and clipped chains plus the disclosure, and the caller
    /// decides what to show and whether to offer clipping.
    static func makeProfile(
        model: String, parametricEQText: String, sampleRate: Double = 44_100
    ) throws -> ImportCandidates {
        let parsed = try ParametricEQParser.parse(
            text: parametricEQText, defaultName: model, sampleRate: sampleRate)
        return parsed.candidates
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
