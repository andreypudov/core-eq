import Foundation

/// One measurement variant of a headphone, as AutoEQ publishes it.
///
/// A model is measured by several sources on several rigs and in several
/// form factors, and each combination is a separate correction. `source` names
/// the measurement database (`oratory1990`, `crinacle`, …), `form` the shape
/// (`over-ear`, `in-ear`, …), and `rig` the fixture used — which is `nil` for
/// roughly ten models whose measurements carry no rig and so cannot be sent to
/// AutoEQ's `/equalize` endpoint.
struct AutoEQVariant: Sendable, Hashable, Codable {
    var source: String
    var rig: String?
    var form: String

    /// A human-friendly label for menus, e.g. `Oratory1990 · over-ear
    /// (GRAS 43AG-7)`.
    ///
    /// AutoEQ's own identifiers are lowercase slugs; the source is title-cased
    /// because it is a proper name, while `form` and `rig` are left as
    /// published so they read as the measurement labels they are.
    var displayName: String {
        var label = "\(Self.titleCased(source)) · \(form)"
        if let rig, !rig.isEmpty {
            label += " (\(rig))"
        }
        return label
    }

    /// A human-friendly name for the measurement source on its own, e.g.
    /// `Oratory1990` or `Rtings`.
    ///
    /// The same title-casing as `displayName`, without the form and rig: it
    /// names who measured the correction, which is what an attribution line
    /// asks for rather than how the measurement was taken.
    var sourceDisplayName: String {
        Self.titleCased(source)
    }

    /// Title-cases a source slug without a locale: the first letter of every
    /// word is upper-cased and the rest left alone, so `oratory1990` becomes
    /// `Oratory1990` and `rtings` becomes `Rtings`.
    private static func titleCased(_ value: String) -> String {
        let words = value.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        guard !words.isEmpty else { return value }
        return words.map { word in
            guard let first = word.first else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

/// A headphone model and every measurement variant AutoEQ has for it.
struct AutoEQModel: Sendable, Hashable, Identifiable {
    var name: String
    var variants: [AutoEQVariant]

    var id: String { name }
}

/// One measurement variant a target accepts, as returned by `/targets`.
///
/// The shape deliberately mirrors `AutoEQVariant` so membership can be tested
/// field by field; it is a separate type because a target's lists are decoded
/// from AutoEQ and never shown on their own.
struct AutoEQTargetVariant: Sendable, Hashable, Codable {
    var source: String
    var rig: String?
    var form: String
}

/// A correction target — Harman, diffuse field, and the like.
struct AutoEQTarget: Sendable, Hashable, Identifiable, Decodable {
    var label: String
    var compatible: [AutoEQTargetVariant]
    var recommended: [AutoEQTargetVariant]

    var id: String { label }

    /// Whether this target can be applied to a measurement with the given
    /// provenance. AutoEQ only accepts a target that lists the variant in
    /// `compatible` or `recommended`.
    func supports(source: String, rig: String?, form: String) -> Bool {
        matches(compatible, source: source, rig: rig, form: form)
            || matches(recommended, source: source, rig: rig, form: form)
    }

    private func matches(
        _ variants: [AutoEQTargetVariant], source: String, rig: String?, form: String
    ) -> Bool {
        // A blank rig in AutoEQ's target data means "any rig" for that source
        // and form, not "no rig". Most targets list oratory1990 and the other
        // form-wide sources that way, so requiring exact equality would hide
        // every applicable target behind an empty dropdown.
        variants.contains {
            $0.source == source && $0.form == form && ($0.rig == nil || $0.rig == rig)
        }
    }
}

/// A single biquad in an equalized profile, as AutoEQ returns it.
struct AutoEQEqualizedFilter: Sendable, Hashable {
    var type: String
    var fc: Double
    var q: Double
    var gain: Double
}

/// AutoEQ's computed parametric equalization for one model, variant, and target.
struct AutoEQEqualizedProfile: Sendable, Hashable {
    var filters: [AutoEQEqualizedFilter]
    var preamp: Double
}

/// The full browsable catalog: every model plus the targets they can be
/// corrected toward.
struct AutoEQCatalog: Sendable {
    var models: [AutoEQModel]
    var targets: [AutoEQTarget]

    /// Models whose full name contains `query`, case- and diacritic-insensitively.
    ///
    /// An empty query is a browse rather than a search and returns the first
    /// `limit` models in catalog order, which keeps the unfiltered list usable
    /// without materializing all six thousand rows.
    func models(matching query: String, limit: Int = 300) -> [AutoEQModel] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(models.prefix(limit)) }

        var result: [AutoEQModel] = []
        for model in models {
            if model.name.range(
                of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            {
                result.append(model)
                if result.count == limit { break }
            }
        }
        return result
    }
}

/// Everything that can go wrong talking to AutoEQ.
enum AutoEQError: Error, LocalizedError, Equatable, Sendable {
    /// No network and no usable cache.
    case offline
    /// The server answered with something other than 200.
    case httpStatus(Int)
    /// The response was not an HTTP response, or was not shaped as expected.
    case invalidResponse
    /// AutoEQ returned an empty model list.
    case emptyCatalog
    /// No target is applicable to the chosen model variant.
    case noMatchingTarget
    /// The variant cannot be equalized by AutoEQ (a `nil` rig).
    case unsupportedVariant
    /// JSON could not be decoded.
    case malformedData
    /// Every filter in an equalized profile used a type CoreEQ cannot render.
    case unsupportedFilter(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "AutoEq could not be reached."
        case .httpStatus(let code):
            return "AutoEq replied with status \(code)."
        case .invalidResponse:
            return "AutoEq replied with an unexpected response."
        case .emptyCatalog:
            return "AutoEq returned an empty catalog."
        case .noMatchingTarget:
            return "No correction target matches this headphone."
        case .unsupportedVariant:
            return "AutoEq cannot equalize this measurement."
        case .malformedData:
            return "AutoEq returned data CoreEQ could not read."
        case .unsupportedFilter(let type):
            return "The profile uses filters CoreEQ cannot render (\(type))."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .offline:
            return "Check your internet connection and try again."
        case .httpStatus, .invalidResponse, .malformedData, .emptyCatalog:
            return "Try again in a moment; AutoEq may be temporarily unavailable."
        case .noMatchingTarget:
            return "Choose a different measurement variant."
        case .unsupportedVariant:
            return "Pick a measurement taken on a known rig instead."
        case .unsupportedFilter:
            return "Choose a different target or variant."
        }
    }
}
