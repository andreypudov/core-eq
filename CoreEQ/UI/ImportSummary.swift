import Foundation

/// The words a dialog uses to describe an import: what was brought in, and
/// anything the parser changed or could not keep.
///
/// Out here rather than in a view because a view is a place tests cannot reach,
/// and every line of this is a sentence someone reads before deciding. The
/// confirmation sheet and the older alert both take their wording from here, so
/// the two can never describe the same adjustment differently.
enum ImportSummary {
    /// How many skipped lines are quoted before the rest are only counted.
    static let quotedLineLimit = 3

    // MARK: - The alert's summary

    /// The body of the "Import Preset?" alert, shown only when an import has
    /// nothing to disclose: what came in, then any skipped lines.
    ///
    /// Composed as one newline-separated string because a macOS alert shows a
    /// single informative text, not a stack of views. Warnings state what
    /// happened and nothing more — the import still succeeds, so the tone stays
    /// informational and the Import button stays the obvious next step.
    static func message(for preview: ProfileManager.ImportPreview) -> String {
        var lines = [
            preview.name,
            "\(preview.filterCount) \(preview.filterCount == 1 ? "filter" : "filters")",
            "Preamp: \(BandFormat.gain(preview.preamp))",
        ]

        if preview.droppedFilterCount > 0 {
            lines.append("")
            lines.append(droppedFiltersSentence(preview.droppedFilterCount))
        }

        if preview.adjustedValueCount > 0 {
            lines.append("")
            lines.append(adjustedValuesSentence(preview.adjustedValueCount))
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

    // MARK: - Shared sentences

    /// "1 value was adjusted …" — the count the alert shows.
    static func adjustedValuesSentence(_ count: Int) -> String {
        let subject = count == 1 ? "value was" : "values were"
        return "\(count) \(subject) adjusted to fit CoreEQ’s limits."
    }

    /// "1 filter was dropped …" — the count the alert shows.
    static func droppedFiltersSentence(_ count: Int) -> String {
        let subject = count == 1 ? "filter was" : "filters were"
        return "\(count) \(subject) dropped to fit CoreEQ’s "
            + "\(BuiltInProfiles.maxFreeFilters)-filter limit."
    }

    /// "2 lines were skipped." — the compact note the sheet shows for an import
    /// that both changes values and leaves lines unmodelled, where the alert's
    /// quoted list would be out of place.
    static func skippedLinesSentence(_ count: Int) -> String {
        count == 1 ? "1 line was skipped." : "\(count) lines were skipped."
    }

    /// A preset named in one line: its name, how many filters it carries, and
    /// its trim. The heading of the confirmation sheet.
    static func presetSummary(_ preview: ProfileManager.ImportPreview) -> String {
        let filters = preview.filterCount == 1 ? "1 filter" : "\(preview.filterCount) filters"
        return "\(preview.name) · \(filters) · Preamp \(BandFormat.gain(preview.preamp))"
    }

    // MARK: - One adjustment, concretely

    /// Names the filter an adjustment belongs to: its source position and
    /// shape. The output trim has no filter, so it is named for what it is.
    ///
    /// `FilterIdentity.index` counts from zero — it is the position in the
    /// parsed list — so the source's own "Filter 1" is shown by adding one.
    static func filterName(_ identity: ImportAdjustment.FilterIdentity?) -> String {
        guard let identity else { return "Output trim" }
        return "Filter \(identity.index + 1) · \(identity.kind.title), "
            + "\(frequencyValue(identity.frequency)) Hz, Q \(qValue(identity.q))"
    }

    /// The original value and the value CoreEQ will store, or that a filter was
    /// dropped. Read with `status(_:)` when it matters whether the change is a
    /// loss or a value merely kept beyond the graphic range.
    static func change(_ adjustment: ImportAdjustment) -> String {
        switch adjustment.kind {
        case .droppedFilter:
            return "dropped"
        case .gain, .preamp:
            return valueChange(adjustment, format: BandFormat.gain)
        case .q:
            return valueChange(adjustment) { "Q \(qValue($0))" }
        case .frequency:
            return valueChange(adjustment) { "\(frequencyValue($0)) Hz" }
        case .keptBeyondBandRange:
            return valueChange(adjustment, format: BandFormat.gain)
        }
    }

    /// One word for what happened, for the row's status: a value CoreEQ had to
    /// change, a filter it had to drop, or a value it kept exactly.
    static func status(_ adjustment: ImportAdjustment) -> String {
        switch adjustment.kind {
        case .droppedFilter: return "Dropped"
        case .keptBeyondBandRange: return "Kept exact"
        default: return "Adjusted"
        }
    }

    /// Which side of the disclosure a row sits on: whether choosing keep-exact
    /// still loses something.
    static func isLoss(_ adjustment: ImportAdjustment) -> Bool {
        adjustment.kind.isLossy
    }

    /// The whole adjustment as one sentence: which filter, what changed, and the
    /// CoreEQ limit responsible.
    static func adjustmentLine(_ adjustment: ImportAdjustment) -> String {
        "\(filterName(adjustment.filter)) — \(change(adjustment)) · \(adjustment.limit)"
    }

    // MARK: - Impact

    /// How far a change moves the response, said plainly, or that it cannot be
    /// measured — never a fabricated zero.
    static func impactSummary(_ impact: ImportImpact) -> String {
        guard let rms = impact.rmsDB, let max = impact.maxDB else {
            return "Not measurable — the correction has a value CoreEQ can’t render."
        }
        if max < 0.005, rms < 0.005 {
            return "No audible change."
        }
        return String(
            format: "Up to %.2f dB difference, %.2f dB RMS, across 20 Hz–20 kHz.", max, rms)
    }

    // MARK: - The catalog's notice

    /// The one-line warning the catalog shows while a preview is loaded: what
    /// saving would change, and how far that moves the response.
    static func notice(for disclosure: ImportDisclosure) -> String {
        var parts: [String] = []

        let adjusted = disclosure.adjustments.filter { $0.kind.isLossy }.count
        if adjusted > 0 {
            let values = adjusted == 1 ? "value" : "values"
            parts.append("Saving will adjust \(adjusted) \(values) to fit CoreEQ’s limits.")
        }

        if disclosure.clippableCount > 0 {
            let kept = disclosure.clippableCount
            let subject = kept == 1 ? "1 value is" : "\(kept) values are"
            parts.append("\(subject) beyond the ±12 dB graphic range.")
        }

        if let max = disclosure.impact.maxDB, let rms = disclosure.impact.rmsDB, max >= 0.05 {
            parts.append(
                String(format: "Response changes by up to %.2f dB (%.2f dB RMS).", max, rms))
        } else if !disclosure.impact.isMeasurable {
            parts.append("The change can’t be measured.")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Small formatting

    /// Clips a skipped line to keep the alert a dialog rather than a wall of
    /// text. The head is what identifies the line; the tail is the parameters
    /// the parser could not model anyway.
    static func clipped(_ line: String, limit: Int = 56) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// A frequency without a thousands separator, with a decimal only when it
    /// has one: "125", "1000", "70.8". The same shape the filter rows use.
    static func frequencyValue(_ hertz: Double) -> String {
        hertz == hertz.rounded() ? String(format: "%.0f", hertz) : String(format: "%.1f", hertz)
    }

    /// A filter Q to two decimals: "1.41".
    static func qValue(_ q: Double) -> String {
        String(format: "%.2f", q)
    }

    /// "original → new" for a value kind, formatted by `format`.
    private static func valueChange(
        _ adjustment: ImportAdjustment, format: (Double) -> String
    ) -> String {
        guard let original = adjustment.original, let adjusted = adjustment.adjusted else {
            return "—"
        }
        return "\(format(original)) → \(format(adjusted))"
    }
}
