import Foundation

/// The body of the "Import Preset?" dialog: what was brought in, then anything
/// the parser changed or could not keep.
///
/// Composed as one newline-separated string because a macOS alert shows a
/// single informative text, not a stack of views. Warnings state what happened
/// and nothing more — the import still succeeds, so the tone stays
/// informational and the Import button stays the obvious next step.
///
/// Out here rather than in the sidebar because a view is a place tests cannot
/// reach, and every line of this is a sentence someone reads before deciding.
enum ImportSummary {
    /// How many skipped lines are quoted before the rest are only counted.
    static let quotedLineLimit = 3

    static func message(for preview: ProfileManager.ImportPreview) -> String {
        var lines = [
            preview.name,
            "\(preview.filterCount) \(preview.filterCount == 1 ? "filter" : "filters")",
            "Preamp: \(BandFormat.gain(preview.preamp))",
        ]

        if preview.droppedFilterCount > 0 {
            let subject = preview.droppedFilterCount == 1 ? "filter was" : "filters were"
            lines.append("")
            lines.append(
                "\(preview.droppedFilterCount) \(subject) dropped to fit CoreEQ’s "
                    + "\(BuiltInProfiles.maxFreeFilters)-filter limit.")
        }

        if preview.adjustedValueCount > 0 {
            let subject = preview.adjustedValueCount == 1 ? "value was" : "values were"
            lines.append("")
            lines.append(
                "\(preview.adjustedValueCount) \(subject) adjusted to fit CoreEQ’s limits.")
        }

        if !preview.unparsedLines.isEmpty {
            let total = preview.unparsedLines.count
            lines.append("")
            lines.append(total == 1 ? "1 line was skipped:" : "\(total) lines were skipped:")
            for line in preview.unparsedLines.prefix(quotedLineLimit) {
                lines.append(clipped(line))
            }
            if total > quotedLineLimit {
                lines.append("… and \(total - quotedLineLimit) more")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Clips a skipped line to keep the alert a dialog rather than a wall of
    /// text. The head is what identifies the line; the tail is the parameters
    /// the parser could not model anyway.
    static func clipped(_ line: String, limit: Int = 56) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
