import Foundation

/// One measurement variant of a headphone, as AutoEQ publishes it.
///
/// A model is measured by several sources on several rigs and in several
/// form factors, and each combination is a separate correction. The result
/// path preserves the exact upstream directory, including spaces and case.
struct AutoEQVariant: Sendable, Hashable, Codable {
    var source: String
    var rig: String?
    var form: String
    var resultPath: String? = nil

    /// A human-friendly label for menus, e.g. `Oratory1990 · over-ear
    /// (GRAS 43AG-7)`.
    ///
    /// The source is title-cased
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

/// One measurement variant a target accepts.
///
/// The shape deliberately mirrors `AutoEQVariant` so membership can be tested
/// field by field; a target's lists are never shown on their own.
struct AutoEQTargetVariant: Sendable, Hashable, Codable {
    var source: String
    var rig: String?
    var form: String
}

/// A correction target — Harman, diffuse field, and the like.
struct AutoEQTarget: Sendable, Hashable, Identifiable, Codable {
    var label: String
    var compatible: [AutoEQTargetVariant]
    var recommended: [AutoEQTargetVariant]

    var fr: AutoEQCurve? = nil
    var bassBoost: AutoEQBassBoost? = nil

    var id: String { label }

    /// Whether this target can be applied to a measurement with the given
    /// provenance. A target lists the variant in
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
struct AutoEQEqualizedFilter: Sendable, Hashable, Codable {
    var type: String
    var fc: Double
    var q: Double
    var gain: Double
}

/// AutoEQ's computed parametric equalization for one model, variant, and target.
struct AutoEQEqualizedProfile: Sendable, Hashable, Codable {
    var filters: [AutoEQEqualizedFilter]
    var preamp: Double
}

/// The full browsable catalog: every model plus the targets they can be
/// corrected toward.
struct AutoEQCatalog: Sendable {
    let models: [AutoEQModel]
    var targets: [AutoEQTarget]
    var revision: String
    var isStale: Bool = false

    /// `models`' names, prepared once rather than on every keystroke.
    private let searchNames: [SearchableName]

    init(models: [AutoEQModel], targets: [AutoEQTarget], revision: String, isStale: Bool = false) {
        self.models = models
        self.targets = targets
        self.revision = revision
        self.isStale = isStale
        searchNames = models.map { SearchableName($0.name) }
    }

    /// Models whose name has every word of `query` in it, by `SearchQuery`'s
    /// rule: names where the words start words first, then catalog order.
    ///
    /// An empty query is a browse rather than a search and returns the first
    /// `limit` models in catalog order, which keeps the unfiltered list usable
    /// without materializing thousands of rows.
    func models(matching query: String, limit: Int = 300) -> [AutoEQModel] {
        guard limit > 0 else { return [] }
        let search = SearchQuery(query)
        guard !search.isEmpty else { return Array(models.prefix(limit)) }

        let ranked = search.ranked(Array(models.indices)) { searchNames[$0] }
        return ranked.prefix(limit).map { models[$0] }
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
    /// The variant has no supported published result path.
    case unsupportedVariant
    /// JSON could not be decoded.
    case malformedData
    /// Every filter in an equalized profile used a type CoreEQ cannot render.
    case unsupportedFilter(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return String(
                localized:
                    "CoreEQ couldn’t download AutoEq data from GitHub. Check your internet connection and try again.",
                comment: "AutoEq error")
        case .httpStatus(let code):
            return code == 403 || code == 429
                ? String(
                    localized: "GitHub is limiting downloads. Try again later.",
                    comment: "AutoEq error: GitHub refused because of too many requests")
                : String(
                    localized: "CoreEQ couldn’t download AutoEq data (HTTP \(code)). Try again.",
                    comment: "AutoEq error: the number is the HTTP status code")
        case .invalidResponse:
            return String(localized: "AutoEq sent an unexpected response.", comment: "AutoEq error")
        case .emptyCatalog:
            return String(localized: "The AutoEq catalog is empty.", comment: "AutoEq error")
        case .noMatchingTarget:
            return String(
                localized: "No correction target matches this model.", comment: "AutoEq error")
        case .unsupportedVariant:
            return String(
                localized: "There’s no published correction CoreEQ supports for this measurement.",
                comment: "AutoEq error")
        case .malformedData:
            return String(
                localized: "AutoEq sent data CoreEQ couldn’t read.", comment: "AutoEq error")
        case .unsupportedFilter(let type):
            return String(
                localized: "The correction uses filters CoreEQ can’t apply (\(type)).",
                comment: "AutoEq error: the filter type code follows in parentheses")
        }
    }

    /// The error in a few English words, for the diagnostics report, which
    /// stays in English whatever language the app is in.
    var diagnosticReason: String {
        switch self {
        case .offline: return "offline"
        case .httpStatus(let code): return "HTTP \(code)"
        case .invalidResponse: return "unexpected response"
        case .emptyCatalog: return "empty catalog"
        case .noMatchingTarget: return "no matching target"
        case .unsupportedVariant: return "unsupported measurement"
        case .malformedData: return "unreadable data"
        case .unsupportedFilter(let type): return "unsupported filter \(type)"
        }
    }
}
