import Foundation

/// Decodes AutoEQ's `/entries` and `/targets` payloads into the catalog model.
///
/// Kept apart from `AutoEQNetworkService` so the wire shapes can be exercised with
/// inline JSON and no network.
enum AutoEQCatalogParser {
    /// Parses the `/entries` object — a map of model name to its variants.
    ///
    /// Names are sorted case-insensitively for a stable browse order; each
    /// model's variants keep the array order AutoEQ returned them in, which is
    /// its own priority order (best measurement first).
    static func parseEntries(_ data: Data) throws -> [AutoEQModel] {
        let decoded: [String: [AutoEQVariant]]
        do {
            decoded = try JSONDecoder().decode([String: [AutoEQVariant]].self, from: data)
        } catch {
            throw AutoEQError.malformedData
        }
        return decoded.map { AutoEQModel(name: $0.key, variants: $0.value) }
            .sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Parses the `/targets` array. Fields CoreEQ does not model — `bassBoost`,
    /// for one — are ignored.
    static func parseTargets(_ data: Data) throws -> [AutoEQTarget] {
        do {
            return try JSONDecoder().decode([AutoEQTarget].self, from: data)
        } catch {
            throw AutoEQError.malformedData
        }
    }
}
