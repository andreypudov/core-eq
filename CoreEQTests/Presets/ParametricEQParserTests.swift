import Foundation
import Testing

@testable import CoreEQ

struct ParametricEQParserTests {
    // MARK: - Parsing EqualizerAPO Format

    @Test func parsesStandardEqualizerAPOText() throws {
        let text = """
            Preamp: -6.4 dB
            Filter 1: ON PK Fc 28 Hz Gain 6.2 dB Q 2.10
            Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
            Filter 3: ON HSC Fc 8000 Hz Gain -3.0 dB Q 0.70
            Filter 4: ON HP Fc 20 Hz Q 0.71
            Filter 5: ON LP Fc 20000 Hz Q 0.71
            """

        let result = try ParametricEQParser.parse(text: text, defaultName: "HD 650")
        #expect(result.name == "HD 650")
        #expect(result.preamp == -6.4)
        #expect(result.autoGain == false)

        // Free filters should contain the 5 parsed items
        let freeFilters = result.filters.filter { !$0.isBand }
        #expect(freeFilters.count == 5)

        #expect(freeFilters[0].kind == .bell)
        #expect(freeFilters[0].frequency == 28)
        #expect(freeFilters[0].gain == 6.2)
        #expect(freeFilters[0].q == 2.10)
        #expect(freeFilters[0].isEnabled == true)

        #expect(freeFilters[1].kind == .lowShelf)
        #expect(freeFilters[1].frequency == 105)
        #expect(freeFilters[1].gain == 5.5)
        #expect(freeFilters[1].q == 0.71)

        #expect(freeFilters[2].kind == .highShelf)
        #expect(freeFilters[2].frequency == 8000)
        #expect(freeFilters[2].gain == -3.0)
        #expect(freeFilters[2].q == 0.70)

        #expect(freeFilters[3].kind == .highPass)
        #expect(freeFilters[3].frequency == 20)
        #expect(freeFilters[3].q == 0.71)

        #expect(freeFilters[4].kind == .lowPass)
        #expect(freeFilters[4].frequency == 20000)
        #expect(freeFilters[4].q == 0.71)
    }

    @Test func parsesDisabledFilter() throws {
        let text = """
            Filter 1: OFF PK Fc 1000 Hz Gain -4.0 dB Q 1.41
            """
        let result = try ParametricEQParser.parse(text: text)
        let freeFilters = result.filters.filter { !$0.isBand }
        #expect(freeFilters.count == 1)
        #expect(freeFilters[0].isEnabled == false)
        #expect(freeFilters[0].gain == -4.0)
    }

    @Test func parsesBandwidthOctaveFormat() throws {
        let text = """
            Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB BW Oct 1.0
            """
        let result = try ParametricEQParser.parse(text: text)
        let freeFilters = result.filters.filter { !$0.isBand }
        #expect(freeFilters.count == 1)
        // For BW 1.0 octave: Q = sqrt(2) / (2 - 1) = 1.4142...
        #expect(abs(freeFilters[0].q - 1.4142) < 0.01)
    }

    @Test func clampsExtremeGainsAndFrequencies() throws {
        let text = """
            Preamp: -25.0 dB
            Filter 1: ON PK Fc 5 Hz Gain 24.0 dB Q 0.01
            Filter 2: ON PK Fc 30000 Hz Gain -30.0 dB Q 50.0
            """
        let result = try ParametricEQParser.parse(text: text)
        #expect(result.preamp == -12.0)  // Clamped to gainRange

        let freeFilters = result.filters.filter { !$0.isBand }
        #expect(freeFilters.count == 2)
        #expect(freeFilters[0].frequency == 20.0)
        #expect(freeFilters[0].gain == 12.0)
        #expect(freeFilters[0].q == 0.1)

        #expect(freeFilters[1].frequency == 20000.0)
        #expect(freeFilters[1].gain == -12.0)
        #expect(freeFilters[1].q == 10.0)
    }

    @Test func capsAtMaximumFreeFilters() throws {
        var lines: [String] = []
        for i in 1...25 {
            lines.append("Filter \(i): ON PK Fc \(100 * i) Hz Gain \(Double(i % 10)) dB Q 1.0")
        }
        let text = lines.joined(separator: "\n")
        let result = try ParametricEQParser.parse(text: text)
        let freeFilters = result.filters.filter { !$0.isBand }
        #expect(freeFilters.count == BuiltInProfiles.maxFreeFilters)
        #expect(result.droppedFilterCount == 25 - BuiltInProfiles.maxFreeFilters)
    }

    @Test func trimmingKeepsPassFiltersAndCountsDrops() throws {
        var lines: [String] = []
        lines.append("Filter 1: ON HP Fc 20 Hz Q 0.71")
        lines.append("Filter 2: ON LP Fc 20000 Hz Q 0.71")
        for i in 3...25 {
            lines.append("Filter \(i): ON PK Fc \(100 * i) Hz Gain \(Double(i % 10)) dB Q 1.0")
        }
        let text = lines.joined(separator: "\n")

        let result = try ParametricEQParser.parse(text: text)
        let freeFilters = result.filters.filter { !$0.isBand }

        #expect(freeFilters.count == BuiltInProfiles.maxFreeFilters)
        #expect(result.droppedFilterCount == 25 - BuiltInProfiles.maxFreeFilters)
        // Gain 0 means the old prominence sort dropped these first.
        #expect(freeFilters.contains { $0.kind == .highPass })
        #expect(freeFilters.contains { $0.kind == .lowPass })
    }

    @Test func capsPassFiltersAndReportsEveryDroppedFilter() throws {
        let lines = (0..<(BuiltInProfiles.maxFreeFilters + 4)).map { index in
            "Filter \(index + 1): ON HP Fc \(20 + index) Hz Q 0.71"
        }
        let result = try ParametricEQParser.parse(text: lines.joined(separator: "\n"))

        #expect(result.filters.filter { !$0.isBand }.count == BuiltInProfiles.maxFreeFilters)
        #expect(result.droppedFilterCount == 4)
    }

    @Test func coreEQJSONCapsFreeFiltersAndReportsDrops() throws {
        let filters = (0..<(BuiltInProfiles.maxFreeFilters + 3)).map { index in
            EQFilter(kind: .bell, frequency: 100 + Double(index), gain: Double(index), q: 1)
        }
        let profile = EQProfile(name: "Oversized", filters: filters)
        let json = String(data: try JSONEncoder().encode(profile), encoding: .utf8)!

        let result = try ParametricEQParser.parse(text: json)

        #expect(result.filters.filter { !$0.isBand }.count == BuiltInProfiles.maxFreeFilters)
        #expect(result.droppedFilterCount == 3)
    }

    @Test func collectsUnknownDirectiveLinesWithoutFailing() throws {
        let text = """
            Preamp: -2.0 dB
            GraphicEQ: 10 -20 30
            Convolution: filter.wav
            Channel: L R
            If: someCondition
            Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.0
            """

        let result = try ParametricEQParser.parse(text: text)
        #expect(result.filters.filter { !$0.isBand }.count == 1)
        #expect(result.droppedFilterCount == 0)
        #expect(result.unparsedLines.count == 4)
        #expect(result.unparsedLines.contains("GraphicEQ: 10 -20 30"))
        #expect(result.unparsedLines.contains("Convolution: filter.wav"))
        #expect(result.unparsedLines.contains("Channel: L R"))
        #expect(result.unparsedLines.contains("If: someCondition"))
    }

    @Test func rejectsEmptyOrInvalidText() {
        #expect(throws: ParametricEQParser.ParseError.emptyContent) {
            try ParametricEQParser.parse(text: "   \n\n  ")
        }
        #expect(throws: ParametricEQParser.ParseError.noValidFiltersFound) {
            try ParametricEQParser.parse(text: "# Some comment\n; Another comment")
        }
    }

    // MARK: - Serialization and Round Trip

    @Test func serializationAndParsingRoundTrip() throws {
        let original = EQProfile(
            name: "Custom Curve",
            filters: FilterChain.normalized([
                EQFilter(kind: .lowShelf, frequency: 100, gain: 4.0, q: 0.7),
                EQFilter(kind: .bell, frequency: 1250, gain: -2.5, q: 2.0),
                EQFilter(kind: .highShelf, frequency: 9000, gain: 3.0, q: 0.7),
            ]),
            preamp: -3.5,
            autoGain: false
        )

        let apoText = ParametricEQSerializer.serializeToEqualizerAPO(original)
        #expect(apoText.contains("Preamp: -3.5 dB"))
        #expect(apoText.contains("LSC Fc 100 Hz Gain 4.0 dB Q 0.70"))
        #expect(apoText.contains("PK Fc 1250 Hz Gain -2.5 dB Q 2.00"))
        #expect(apoText.contains("HSC Fc 9000 Hz Gain 3.0 dB Q 0.70"))

        let parsed = try ParametricEQParser.parse(text: apoText, defaultName: "Custom Curve")
        #expect(parsed.name == original.name)
        #expect(parsed.preamp == original.preamp)

        let parsedFree = parsed.filters.filter { !$0.isBand }
        #expect(parsedFree.count == 3)
        #expect(parsedFree[0].frequency == 100)
        #expect(parsedFree[0].gain == 4.0)
        #expect(parsedFree[1].frequency == 1250)
        #expect(parsedFree[1].gain == -2.5)
        #expect(parsedFree[2].frequency == 9000)
        #expect(parsedFree[2].gain == 3.0)
    }

    @Test func coreEQJSONRoundTrip() throws {
        let original = EQProfile(
            name: "Studio Reference",
            filters: FilterChain.normalized([
                EQFilter(kind: .bell, frequency: 3200, gain: 1.5, q: 1.8)
            ]),
            preamp: -1.0,
            autoGain: true
        )

        let json = try ParametricEQSerializer.serializeToCoreEQJSON(original)
        let parsed = try ParametricEQParser.parse(text: json)

        #expect(parsed.name == "Studio Reference")
        #expect(parsed.preamp == -1.0)
        #expect(parsed.autoGain == true)
        #expect(parsed.filters.filter { !$0.isBand }.count == 1)
    }

    @Test func fractionalAutoEQValuesRoundTripAccurately() throws {
        let text = """
            Preamp: -2.99 dB
            Filter 1: ON LSC Fc 105.0 Hz Gain -1.9 dB Q 0.70
            Filter 2: ON PK Fc 74.3 Hz Gain 1.2 dB Q 1.50
            Filter 3: ON PK Fc 1829.9 Hz Gain -3.6 dB Q 1.64
            Filter 4: ON PK Fc 5213.3 Hz Gain 1.2 dB Q 5.99
            Filter 5: ON HSC Fc 10000.0 Hz Gain -5.7 dB Q 0.70
            """

        let parsed = try ParametricEQParser.parse(text: text, defaultName: "ARTTI T10")
        #expect(parsed.preamp == -2.99)

        let freeFilters = parsed.filters.filter { !$0.isBand }
        #expect(freeFilters.count == 5)
        #expect(freeFilters[1].frequency == 74.3)
        #expect(freeFilters[1].gain == 1.2)
        #expect(freeFilters[1].q == 1.50)
        #expect(freeFilters[2].frequency == 1829.9)
        #expect(freeFilters[2].gain == -3.6)
        #expect(freeFilters[2].q == 1.64)
        #expect(freeFilters[3].frequency == 5213.3)
        #expect(freeFilters[3].q == 5.99)

        let serialized = ParametricEQSerializer.serializeToEqualizerAPO(
            EQProfile(name: "ARTTI T10", filters: parsed.filters, preamp: parsed.preamp)
        )
        #expect(serialized.contains("Preamp: -3.0 dB"))
        #expect(serialized.contains("PK Fc 74 Hz Gain 1.2 dB Q 1.50"))
        #expect(serialized.contains("PK Fc 1830 Hz Gain -3.6 dB Q 1.64"))
        #expect(serialized.contains("PK Fc 5213 Hz Gain 1.2 dB Q 5.99"))
        #expect(serialized.contains("HSC Fc 10000 Hz Gain -5.7 dB Q 0.70"))
    }

    @Test func rejectsUnsupportedFilterKinds() {
        let invalidFilterText = """
            Preamp: -2.0 dB
            Filter 1: ON UNKNOWN_KIND Fc 1000 Hz Gain 3.0 dB Q 1.00
            Filter 2: ON INVALID Fc 500 Hz Gain 2.0 dB Q 0.70
            """
        #expect(throws: ParametricEQParser.ParseError.unsupportedFilterDeclaration) {
            try ParametricEQParser.parse(text: invalidFilterText)
        }
    }

    @Test func mixedSupportedAndUnsupportedFiltersFailExplicitly() {
        let text = """
            Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.00
            Filter 2: ON NOTCH Fc 2000 Hz Gain -2 dB Q 1.00
            """
        #expect(throws: ParametricEQParser.ParseError.unsupportedFilterDeclaration) {
            try ParametricEQParser.parse(text: text)
        }
    }
}
