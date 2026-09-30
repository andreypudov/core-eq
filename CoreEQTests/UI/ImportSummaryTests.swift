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
        let one = try summary("Filter 1: ON PK Fc 1000 Hz Gain 20.0 dB Q 1.00")
        #expect(one.contains("1 value was adjusted to fit CoreEQ’s limits."))

        let three = try summary("Filter 1: ON PK Fc 5 Hz Gain 20.0 dB Q 50.0")
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
}
