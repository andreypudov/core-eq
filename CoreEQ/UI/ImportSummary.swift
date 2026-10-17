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
            String(
                localized: "\(preview.filterCount) filters", bundle: .coreEQ,
                comment: "Import alert: how many filters the preset brings in"),
            String(
                localized: "Preamp: \(BandFormat.gain(preview.preamp))",
                comment: "Import alert: the preset’s output trim, such as “Preamp: −6.0 dB”"),
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
            lines.append(
                String(
                    localized: "\(total) lines were skipped:", bundle: .coreEQ,
                    comment: "Import alert: introduces the quoted lines the parser couldn’t read"))
            for line in preview.unparsedLines.prefix(quotedLineLimit) {
                lines.append(clipped(line))
            }
            if total > quotedLineLimit {
                lines.append(
                    String(
                        localized: "… and \(total - quotedLineLimit) more",
                        comment: "Import alert: how many skipped lines are not quoted"))
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Shared sentences

    /// "1 value was adjusted …" — the count the alert shows.
    static func adjustedValuesSentence(_ count: Int) -> String {
        String(
            localized: "\(count) values were adjusted to fit CoreEQ’s limits.", bundle: .coreEQ,
            comment: "Import alert: how many values CoreEQ changed")
    }

    /// "1 filter was dropped …" — the count the alert shows.
    static func droppedFiltersSentence(_ count: Int) -> String {
        String(
            localized:
                "\(count) filters were dropped to fit CoreEQ’s \(BuiltInProfiles.maxFreeFilters)-filter limit.",
            bundle: .coreEQ,
            comment: "Import alert: how many filters didn’t fit, and how many CoreEQ holds")
    }

    /// "2 lines were skipped." — the compact note the sheet shows for an import
    /// that both changes values and leaves lines unmodelled, where the alert's
    /// quoted list would be out of place.
    static func skippedLinesSentence(_ count: Int) -> String {
        String(
            localized: "\(count) lines were skipped.", bundle: .coreEQ,
            comment: "Import sheet: how many lines of the file the parser couldn’t read")
    }

    /// A preset named in one line: its name, how many filters it carries, and
    /// its trim. The heading of the confirmation sheet.
    static func presetSummary(_ preview: ProfileManager.ImportPreview) -> String {
        String(
            localized:
                "\(preview.name) · \(preview.filterCount) filters · Preamp \(BandFormat.gain(preview.preamp))",
            bundle: .coreEQ,
            comment: "Import sheet heading: preset name, filter count, and output trim")
    }

    // MARK: - One adjustment, concretely

    /// Names the filter an adjustment belongs to: its source position and
    /// shape. The output trim has no filter, so it is named for what it is.
    ///
    /// `FilterIdentity.index` counts from zero — it is the position in the
    /// parsed list — so the source's own "Filter 1" is shown by adding one.
    static func filterName(_ identity: ImportAdjustment.FilterIdentity?) -> String {
        guard let identity else {
            return String(
                localized: "Output trim", comment: "Import sheet: the adjusted value is the preamp")
        }
        return String(
            localized:
                "Filter \(identity.index + 1) · \(identity.kind.title), \(frequencyValue(identity.frequency)) Hz, Q \(qValue(identity.q))",
            comment: "Import sheet: which filter of the file, its type, frequency, and Q")
    }

    /// The original value and the value CoreEQ will store, or that a filter was
    /// dropped. Read with `status(_:)` when it matters whether the change is a
    /// loss or a value merely kept beyond the graphic range.
    static func change(_ adjustment: ImportAdjustment) -> String {
        switch adjustment.kind {
        case .droppedFilter:
            return String(
                localized: "dropped", comment: "Import sheet: a filter that won’t be imported")
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
        case .droppedFilter:
            return String(localized: "Dropped", comment: "Import sheet status: filter not imported")
        case .keptBeyondBandRange:
            return String(
                localized: "Kept exact", comment: "Import sheet status: value imported unchanged")
        default:
            return String(localized: "Adjusted", comment: "Import sheet status: value changed")
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
        String(
            localized:
                "\(filterName(adjustment.filter)): \(change(adjustment)) · \(adjustment.limit)",
            comment: "Import: which filter, what changed, and the CoreEQ limit responsible")
    }

    // MARK: - Impact

    /// How far a change moves the response, said plainly, or that it cannot be
    /// measured — never a fabricated zero.
    static func impactSummary(_ impact: ImportImpact) -> String {
        guard let rms = impact.rmsDB, let max = impact.maxDB else {
            return String(
                localized: "Not measurable: the correction has a value CoreEQ can’t render.",
                comment: "Import sheet: why the change to the response can’t be measured")
        }
        if max < 0.005, rms < 0.005 {
            return String(
                localized: "No audible change.", comment: "Import sheet: the response is unchanged")
        }
        return String(
            localized:
                "Up to \(decibels(max)) dB difference, \(decibels(rms)) dB RMS, across 20 Hz–20 kHz.",
            comment: "Import sheet: the largest and the average change to the response")
    }

    // MARK: - The catalog's notice

    /// The one-line warning the catalog shows while a preview is loaded: what
    /// saving would change, and how far that moves the response.
    static func notice(for disclosure: ImportDisclosure) -> String {
        var parts: [String] = []

        let adjusted = disclosure.adjustments.filter { $0.kind.isLossy }.count
        if adjusted > 0 {
            parts.append(
                String(
                    localized: "Saving will adjust \(adjusted) values to fit CoreEQ’s limits.",
                    bundle: .coreEQ,
                    comment: "AutoEq catalog notice: how many values importing would change"))
        }

        if disclosure.clippableCount > 0 {
            parts.append(
                String(
                    localized:
                        "\(disclosure.clippableCount) values are beyond the ±12 dB graphic range.",
                    bundle: .coreEQ,
                    comment: "AutoEq catalog notice: values kept outside the graphic sliders’ range"
                ))
        }

        if let max = disclosure.impact.maxDB, let rms = disclosure.impact.rmsDB, max >= 0.05 {
            parts.append(
                String(
                    localized:
                        "Response changes by up to \(decibels(max)) dB (\(decibels(rms)) dB RMS).",
                    comment: "AutoEq catalog notice: the largest and the average change"))
        } else if !disclosure.impact.isMeasurable {
            parts.append(
                String(
                    localized: "The change can’t be measured.",
                    comment: "AutoEq catalog notice: the change to the response is unknown"))
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

    /// A difference in decibels to two decimals: "0.25".
    private static func decibels(_ value: Double) -> String {
        String(format: "%.2f", value)
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
