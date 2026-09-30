import Foundation
import Testing

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
        // The file set its own trim.
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
        #expect(result.preamp == -12.0)  // Clamped to preampRange

        let freeFilters = result.filters.filter { !$0.isBand }
        #expect(freeFilters.count == 2)
        #expect(freeFilters[0].frequency == 20.0)
        #expect(freeFilters[0].gain == 12.0)
        #expect(freeFilters[0].q == 0.1)

        #expect(freeFilters[1].frequency == 20000.0)
        #expect(freeFilters[1].gain == -12.0)
        #expect(freeFilters[1].q == 10.0)

        // The preamp, and all three values of each filter.
        #expect(result.adjustedValueCount == 7)
    }

    @Test func droppedFiltersAreNotCountedAsAdjusted() throws {
        // Sixteen in range, and one weak filter at 5 Hz: the weakest is the one
        // trimmed, so its out-of-range frequency never reaches the preset.
        var lines = (1...BuiltInProfiles.maxFreeFilters).map {
            "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 6.0 dB Q 1.00"
        }
        lines.append("Filter 17: ON PK Fc 5 Hz Gain 0.5 dB Q 1.00")

        let result = try ParametricEQParser.parse(text: lines.joined(separator: "\n"))
        #expect(result.droppedFilterCount == 1)
        #expect(result.adjustedValueCount == 0)
    }

    @Test func coreEQBandCountsOnlyItsGain() throws {
        // A ladder band's frequency and Q are the ladder's, whatever the file
        // says, so only an out-of-range gain is a change the user would see.
        let band = EQFilter(kind: .bell, frequency: 5, gain: 20, q: 50, band: 0)
        let json = try ParametricEQSerializer.serializeToCoreEQJSON(
            EQProfile(name: "Band", filters: [band]))

        let result = try ParametricEQParser.parse(text: json)
        #expect(result.adjustedValueCount == 1)
        #expect(result.filters.first?.gain == BuiltInProfiles.gainRange.upperBound)
    }

    @Test func valuesInRangeAreNotReportedAsAdjusted() throws {
        let result = try ParametricEQParser.parse(
            text: "Preamp: -12.0 dB\nFilter 1: ON PK Fc 20 Hz Gain 12.0 dB Q 10.0")
        #expect(result.adjustedValueCount == 0)
    }

    @Test func coreEQJSONOutOfRangeValuesAreClampedAndReported() throws {
        let profile = EQProfile(
            name: "Hand Edited",
            filters: [EQFilter(kind: .bell, frequency: 1000, gain: 30, q: 1)],
            preamp: -40)
        let json = try ParametricEQSerializer.serializeToCoreEQJSON(profile)

        let result = try ParametricEQParser.parse(text: json)
        #expect(result.preamp == BuiltInProfiles.preampRange.lowerBound)
        #expect(result.filters.filter { !$0.isBand }.first?.gain == 12)
        #expect(result.adjustedValueCount == 2)
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

    @Test func textWithoutPreampLineComputesItsTrim() throws {
        let result = try ParametricEQParser.parse(
            text: "Filter 1: ON PK Fc 100 Hz Gain 9.0 dB Q 1.00")
        #expect(result.preamp == 0)
        #expect(result.autoGain == true)
    }

    @Test func preampLineAloneIsAFlatPreset() throws {
        let result = try ParametricEQParser.parse(text: "Preamp: -3.0 dB")
        #expect(result.preamp == -3.0)
        #expect(result.autoGain == false)
        #expect(result.filters.filter { !$0.isBand }.isEmpty)
    }

    @Test func damagedCoreEQFileReportsDamageNotMissingFilters() {
        #expect(throws: ParametricEQParser.ParseError.damagedCoreEQFile) {
            try ParametricEQParser.parse(text: #"{ "name": "Truncated", "filters": [ "#)
        }
    }

    // MARK: - Text Encodings

    private static let apoText = "Preamp: -2.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.00\n"

    @Test func decodesUTF16LittleEndianWithBOM() throws {
        var data = Data([0xFF, 0xFE])
        data.append(Self.apoText.data(using: .utf16LittleEndian)!)

        let text = try ParametricEQParser.decodeText(data)
        #expect(text == Self.apoText)
        #expect(try ParametricEQParser.parse(text: text).preamp == -2.0)
    }

    @Test func decodesUTF16BigEndianWithBOM() throws {
        var data = Data([0xFE, 0xFF])
        data.append(Self.apoText.data(using: .utf16BigEndian)!)

        #expect(try ParametricEQParser.decodeText(data) == Self.apoText)
    }

    @Test func rejectsBytesThatAreNotText() {
        // 0x81 is neither valid UTF-8 nor defined in Windows-1252.
        var data = Data("Preamp: -2.0 dB\n".utf8)
        data.append(contentsOf: [0x81, 0x8D])

        #expect(throws: ParametricEQParser.ParseError.unreadableText) {
            try ParametricEQParser.decodeText(data)
        }
    }

    @Test func decodesUTF8WithBOM() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(Self.apoText.utf8))

        let text = try ParametricEQParser.decodeText(data)
        #expect(try ParametricEQParser.parse(text: text).preamp == -2.0)
    }

    @Test func decodesWindows1252() throws {
        // "# Réglage" in Windows-1252: 0xE9 alone is not valid UTF-8.
        var data = Data("# R".utf8)
        data.append(0xE9)
        data.append(Data("glage\n\(Self.apoText)".utf8))

        let text = try ParametricEQParser.decodeText(data)
        #expect(text.hasPrefix("# Réglage"))
        #expect(try ParametricEQParser.parse(text: text).preamp == -2.0)
    }

    // MARK: - Serialization and Round Trip

    @Test func disabledFilterExportsAsOffAndReturnsDisabled() throws {
        let profile = EQProfile(
            name: "Bypassed",
            filters: FilterChain.normalized([
                EQFilter(kind: .bell, frequency: 1000, gain: 3, q: 1, isEnabled: false)
            ]))
        let text = ParametricEQSerializer.serializeToEqualizerAPO(profile)
        #expect(text.contains("Filter 1: OFF PK Fc 1000.0 Hz"))

        let parsed = try ParametricEQParser.parse(text: text)
        #expect(parsed.filters.filter { !$0.isBand }.first?.isEnabled == false)
    }

    /// What a filter is, without the colour — colour is not part of the
    /// EqualizerAPO format, so it cannot survive a round trip through it.
    private func shape(_ filters: [EQFilter]) -> [String] {
        filters.map {
            "\($0.kind) \($0.frequency) \($0.gain) \($0.q) \($0.isEnabled) \(String(describing: $0.band))"
        }
    }

    /// The roadmap's criterion: what CoreEQ writes out reloads identically.
    /// This is the preset that failed it — six edited ladder bands and twelve
    /// filters, eighteen lines, of which two were dropped and six came back as
    /// filters instead of bands.
    @Test func equalizerAPOExportReloadsIdentically() throws {
        var bands = BuiltInProfiles.emptyBandChain()
        for (slot, gain) in [(0, 1.75), (1, 3.25), (2, -2.5), (5, 2.37), (8, -0.5), (10, 6.0)] {
            bands[slot].gain = gain
        }
        let free: [EQFilter] = [
            EQFilter(kind: .bell, frequency: 60, gain: -5.25, q: 0.5),
            EQFilter(kind: .lowShelf, frequency: 105, gain: 3.5, q: 0.7),
            EQFilter(kind: .highShelf, frequency: 9_000, gain: -2.75, q: 0.7),
            EQFilter(kind: .highPass, frequency: 25, gain: 0, q: 0.71),
            EQFilter(kind: .lowPass, frequency: 18_500, gain: 0, q: 0.71, isEnabled: false),
            EQFilter(kind: .bell, frequency: 74.3, gain: 1.2, q: 1.5),
            EQFilter(kind: .bell, frequency: 1_829.9, gain: -3.6, q: 1.64),
            EQFilter(kind: .bell, frequency: 5_213.3, gain: 1.2, q: 5.99),
            EQFilter(kind: .bell, frequency: 1_000, gain: 2.0, q: 2.5),
            EQFilter(kind: .bell, frequency: 3_150, gain: -4.25, q: 3.0),
            EQFilter(kind: .bell, frequency: 12_000, gain: 1.75, q: 0.9),
            EQFilter(kind: .bell, frequency: 440, gain: -1.5, q: 4.37),
        ]
        let original = EQProfile(
            name: "Mine", filters: FilterChain.normalized(bands + free), preamp: -2.37,
            autoGain: false)

        let parsed = try ParametricEQParser.parse(
            text: ParametricEQSerializer.serializeToEqualizerAPO(original))

        #expect(parsed.droppedFilterCount == 0)
        #expect(parsed.preamp == original.preamp)
        #expect(shape(parsed.filters) == shape(original.filters))
    }

    @Test func aFilterThatIsExactlyARungReturnsToTheLadder() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Filter 1: ON PK Fc 1000.0 Hz Gain 3.0 dB Q 1.41")
        #expect(parsed.filters[5].gain == 3.0)
        #expect(parsed.filters.filter { !$0.isBand }.isEmpty)
    }

    /// Anything the ladder cannot express stays a filter: another Q, a
    /// disabled filter, and a second one on a rung already taken.
    @Test func onlyAnExactRungReturnsToTheLadder() throws {
        let text = """
            Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.00
            Filter 2: OFF PK Fc 2000 Hz Gain 2.0 dB Q 1.41
            Filter 3: ON PK Fc 4000 Hz Gain 1.0 dB Q 1.41
            Filter 4: ON PK Fc 4000 Hz Gain -1.0 dB Q 1.41
            Filter 5: ON LSC Fc 125 Hz Gain 2.0 dB Q 1.41
            """
        let parsed = try ParametricEQParser.parse(text: text)
        let free = parsed.filters.filter { !$0.isBand }
        #expect(parsed.filters[7].gain == 1.0)
        #expect(free.count == 4)
        #expect(free.map(\.frequency) == [1000, 2000, 4000, 125])
    }

    @Test func numbersAreWrittenAsPreciselyAsTheyAre() {
        #expect(ParametricEQSerializer.formatGain(1.75) == "1.75")
        #expect(ParametricEQSerializer.formatGain(2) == "2.0")
        #expect(ParametricEQSerializer.formatGain(-2.37) == "-2.37")
        #expect(ParametricEQSerializer.formatGain(-0.00001) == "0.0")
        #expect(ParametricEQSerializer.formatFrequency(105) == "105.0")
        #expect(ParametricEQSerializer.formatFrequency(74.3) == "74.3")
        #expect(ParametricEQSerializer.formatQ(0.7) == "0.70")
        #expect(ParametricEQSerializer.formatQ(1.234567) == "1.2346")
    }

    @Test func flatExportImportsAgain() throws {
        let flat = EQProfile(name: "Flat", filters: BuiltInProfiles.emptyBandChain())
        let text = ParametricEQSerializer.serializeToEqualizerAPO(flat)

        let parsed = try ParametricEQParser.parse(text: text)
        #expect(parsed.preamp == 0)
        #expect(parsed.filters == flat.filters)
    }

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
        #expect(apoText.contains("LSC Fc 100.0 Hz Gain 4.0 dB Q 0.70"))
        #expect(apoText.contains("PK Fc 1250.0 Hz Gain -2.5 dB Q 2.00"))
        #expect(apoText.contains("HSC Fc 9000.0 Hz Gain 3.0 dB Q 0.70"))

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
        // Written as it was read, not rounded to AutoEQ's one decimal.
        #expect(serialized.contains("Preamp: -2.99 dB"))
        #expect(serialized.contains("PK Fc 74.3 Hz Gain 1.2 dB Q 1.50"))
        #expect(serialized.contains("PK Fc 1829.9 Hz Gain -3.6 dB Q 1.64"))
        #expect(serialized.contains("PK Fc 5213.3 Hz Gain 1.2 dB Q 5.99"))
        #expect(serialized.contains("HSC Fc 10000.0 Hz Gain -5.7 dB Q 0.70"))
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
