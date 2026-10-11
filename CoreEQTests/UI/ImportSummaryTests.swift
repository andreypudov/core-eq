import Foundation
import Testing

/// What the "Import Preset?" dialog says. Previews are made by parsing real
/// preset text, the only way the app makes them.
@MainActor
struct ImportSummaryTests {
    private let manager = ProfileManager(settings: SettingsStore(defaults: InMemoryDefaults()))

    private func summary(_ text: String, name: String = "HD 600") throws -> String {
        ImportSummary.message(for: try manager.previewImport(text: text, suggestedName: name))
    }

    private static func filters(_ count: Int, gain: Double = 3) -> [String] {
        (1...count).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain \(gain) dB Q 1.00" }
    }

    @Test func cleanImportIsNameCountAndPreamp() throws {
        let text = "Preamp: -3.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00"
        #expect(try summary(text) == "HD 600\n1 filter\nPreamp: -3.0 dB")
    }

    @Test func countsInThePluralAndSignsABoost() throws {
        let text = (["Preamp: 2.0 dB"] + Self.filters(2)).joined(separator: "\n")
        #expect(try summary(text) == "HD 600\n2 filters\nPreamp: +2.0 dB")
    }

    @Test func reportsDroppedFilters() throws {
        let count = BuiltInProfiles.maxFreeFilters + 1
        let message = try summary(Self.filters(count).joined(separator: "\n"))
        #expect(
            message.contains(
                "1 filter was dropped to fit CoreEQ’s \(BuiltInProfiles.maxFreeFilters)-filter limit."
            ))
    }

    @Test func reportsAdjustedValues() throws {
        let one = try summary("Filter 1: ON PK Fc 1000 Hz Gain 25.0 dB Q 1.00")
        #expect(one.contains("1 value was adjusted to fit CoreEQ’s limits."))

        let three = try summary("Filter 1: ON PK Fc 5 Hz Gain 25.0 dB Q 50.0")
        #expect(three.contains("3 values were adjusted to fit CoreEQ’s limits."))
    }

    @Test func saysNothingAboutAdjustingWhenNothingWas() throws {
        let message = try summary("Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00")
        #expect(!message.contains("adjusted"))
        #expect(!message.contains("dropped"))
        #expect(!message.contains("skipped"))
    }

    @Test func quotesTheFirstSkippedLinesAndCountsTheRest() throws {
        let skipped = ["Channel: L", "GraphicEQ: 10 0", "Convolution: a.wav", "If: x", "Eval: y"]
        let text = (skipped + Self.filters(1)).joined(separator: "\n")
        let lines = try summary(text).components(separatedBy: "\n")

        #expect(lines.contains("5 lines were skipped:"))
        for line in skipped.prefix(ImportSummary.quotedLineLimit) {
            #expect(lines.contains(line))
        }
        #expect(!lines.contains("If: x"))
        #expect(lines.last == "… and 2 more")
    }

    @Test func oneSkippedLineIsQuotedWithoutACount() throws {
        let text = (["Channel: L"] + Self.filters(1)).joined(separator: "\n")
        let lines = try summary(text).components(separatedBy: "\n")
        #expect(lines.suffix(2) == ["1 line was skipped:", "Channel: L"])
    }

    @Test func clipsLongLinesToTheLimit() {
        let long = String(repeating: "x", count: 80)
        let clipped = ImportSummary.clipped(long)
        #expect(clipped.count == 56)
        #expect(clipped.hasSuffix("…"))

        #expect(ImportSummary.clipped("  GraphicEQ: 10 0  ") == "GraphicEQ: 10 0")
    }

    // MARK: - The Confirmation Sheet's Wording

    private func preview(
        _ text: String, name: String = "HD 600"
    ) throws
        -> ProfileManager.ImportPreview
    {
        try manager.previewImport(text: text, suggestedName: name)
    }

    private func adjustment(
        _ kind: ImportAdjustment.Kind, in preview: ProfileManager.ImportPreview
    ) throws -> ImportAdjustment {
        try #require(preview.disclosure.adjustments.first { $0.kind == kind })
    }

    @Test func namesTheFilterAnAdjustmentBelongsTo() throws {
        // The parser counts from zero; the sheet shows the source's own number.
        let gain = try adjustment(
            .gain, in: preview("Filter 1: ON PK Fc 1000 Hz Gain 25.0 dB Q 1.00"))
        #expect(ImportSummary.filterName(gain.filter) == "Filter 1 · Bell, 1000 Hz, Q 1.00")

        // The output trim has no filter, so it is named for what it is.
        let preamp = try adjustment(
            .preamp,
            in: preview("Preamp: -20 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.00"))
        #expect(ImportSummary.filterName(preamp.filter) == "Output trim")
    }

    @Test func showsOriginalAndNewValuePerKind() throws {
        let gain = try adjustment(
            .gain, in: preview("Filter 1: ON PK Fc 1000 Hz Gain -25 dB Q 1.00"))
        #expect(ImportSummary.change(gain) == "-25.0 dB → -20.0 dB")
        #expect(ImportSummary.status(gain) == "Adjusted")
        #expect(ImportSummary.isLoss(gain))

        let q = try adjustment(.q, in: preview("Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 50"))
        #expect(ImportSummary.change(q) == "Q 50.00 → Q 10.00")

        let frequency = try adjustment(
            .frequency, in: preview("Filter 1: ON PK Fc 5 Hz Gain 3 dB Q 1.00"))
        #expect(ImportSummary.change(frequency) == "5 Hz → 20 Hz")

        let preamp = try adjustment(
            .preamp,
            in: preview("Preamp: -20 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.00"))
        #expect(ImportSummary.change(preamp) == "-20.0 dB → -12.0 dB")
    }

    @Test func reportsADroppedFilter() throws {
        var lines = (1...BuiltInProfiles.maxFreeFilters).map {
            "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 6.0 dB Q 1.00"
        }
        lines.append("Filter 17: ON PK Fc 5 Hz Gain 0.5 dB Q 1.00")
        let dropped = try adjustment(.droppedFilter, in: preview(lines.joined(separator: "\n")))

        #expect(ImportSummary.change(dropped) == "dropped")
        #expect(ImportSummary.status(dropped) == "Dropped")
        #expect(ImportSummary.isLoss(dropped))
        #expect(ImportSummary.filterName(dropped.filter) == "Filter 17 · Bell, 5 Hz, Q 1.00")
    }

    @Test func keptBeyondBandRangeReadsAsPreserved() throws {
        let kept = try adjustment(
            .keptBeyondBandRange, in: preview("Filter 1: ON PK Fc 125 Hz Gain 15 dB Q 1.41"))

        // Original and new are the same value: nothing is lost by keeping it.
        #expect(ImportSummary.change(kept) == "+15.0 dB → +15.0 dB")
        #expect(ImportSummary.status(kept) == "Kept exact")
        #expect(!ImportSummary.isLoss(kept))
    }

    @Test func oneAdjustmentReadsAsOneLine() throws {
        let gain = try adjustment(
            .gain, in: preview("Filter 1: ON PK Fc 1000 Hz Gain -25 dB Q 1.00"))
        #expect(
            ImportSummary.adjustmentLine(gain)
                == "Filter 1 · Bell, 1000 Hz, Q 1.00 — -25.0 dB → -20.0 dB · ±20 dB")
    }

    @Test func aMixedImportCountsItsSkippedLines() {
        #expect(ImportSummary.skippedLinesSentence(1) == "1 line was skipped.")
        #expect(ImportSummary.skippedLinesSentence(4) == "4 lines were skipped.")
    }

    @Test func summaryNamesThePresetInOneLine() throws {
        let preview = try preview(
            "Preamp: -3.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00")
        #expect(ImportSummary.presetSummary(preview) == "HD 600 · 1 filter · Preamp -3.0 dB")
    }

    // MARK: - Impact

    @Test func impactReadsAsADifference() {
        let impact = ImportImpact(rmsDB: 1.2, maxDB: 3.4)
        #expect(
            ImportSummary.impactSummary(impact)
                == "Up to 3.40 dB difference, 1.20 dB RMS, across 20 Hz–20 kHz.")
    }

    @Test func aChangeThatMovesNothingSaysSo() {
        #expect(ImportSummary.impactSummary(.none) == "No audible change.")
    }

    @Test func unmeasurableImpactSaysSoRatherThanZero() {
        #expect(
            ImportSummary.impactSummary(.unmeasurable)
                == "Not measurable — the correction has a value CoreEQ can’t render.")
    }

    // MARK: - The Catalog's Notice

    @Test func noticeCountsValuesAndQuotesTheImpact() throws {
        let disclosure = try preview(
            "Preamp: -20 dB\nFilter 1: ON PK Fc 1000 Hz Gain -25 dB Q 1.00"
        ).disclosure
        let notice = ImportSummary.notice(for: disclosure)
        #expect(notice.contains("Saving will adjust 2 values to fit CoreEQ’s limits."))
        #expect(notice.contains("Response changes by up to"))
    }

    @Test func noticeMentionsValuesBeyondTheGraphicRange() throws {
        let disclosure = try preview("Filter 1: ON PK Fc 125 Hz Gain 15 dB Q 1.41").disclosure
        let notice = ImportSummary.notice(for: disclosure)
        #expect(notice.contains("1 value is beyond the ±12 dB graphic range."))
        #expect(!notice.contains("Saving will adjust"))
    }
}
