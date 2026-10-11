import Foundation

/// Reads the upstream result index without redistributing measurements.
enum AutoEQCatalogParser {
    static let defaultTargetLabel = "AutoEq published target"

    static func parseIndex(
        _ data: Data, revision: String, isStale: Bool = false
    ) throws
        -> AutoEQCatalog
    {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutoEQError.malformedData
        }
        var grouped: [String: [AutoEQVariant]] = [:]
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("- [") {
            guard let start = line.range(of: "](./"),
                let end = line.range(of: ") by ", options: .backwards),
                start.upperBound < end.lowerBound,
                let path = String(line[start.upperBound..<end.lowerBound]).removingPercentEncoding,
                let parts = resultComponents(path)
            else { continue }
            let folder = parts[1]
            let form = ["over-ear", "in-ear", "earbud"].first {
                folder == $0 || folder.hasSuffix(" " + $0)
            }
            guard let form else { continue }
            let rig = folder == form ? nil : String(folder.dropLast(form.count + 1))
            let variant = AutoEQVariant(
                source: parts[0], rig: rig, form: form, resultPath: path)
            if !(grouped[parts[2]] ?? []).contains(variant) {
                grouped[parts[2], default: []].append(variant)
            }
        }
        let models = grouped.map { AutoEQModel(name: $0.key, variants: $0.value) }
            .sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
        guard !models.isEmpty else { throw AutoEQError.emptyCatalog }
        let variants = models.flatMap(\.variants).map {
            AutoEQTargetVariant(source: $0.source, rig: $0.rig, form: $0.form)
        }
        return AutoEQCatalog(
            models: models,
            targets: [
                AutoEQTarget(
                    label: defaultTargetLabel, compatible: [], recommended: variants)
            ],
            revision: revision, isStale: isStale)
    }

    /// Accept only relative, three-component result directories. Crinacle is
    /// rejected at both ingestion and the profile download boundary.
    static func resultComponents(_ path: String) -> [String]? {
        let parts = path.components(separatedBy: "/")
        guard parts.count == 3,
            parts.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
                    && !$0.contains("\\")
                    && $0.unicodeScalars.allSatisfy {
                        $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value)
                    }
            }),
            !parts[0].localizedCaseInsensitiveContains("crinacle")
        else { return nil }
        return parts
    }
}
