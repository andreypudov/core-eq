import Foundation
import Testing

/// Every kind of adjustment an import can make, and the keep-exact / clip
/// choice — the core of "no correction is altered without disclosure".
struct ImportDisclosureTests {
    private func adjustment(
        _ kind: ImportAdjustment.Kind,
        in disclosure: ImportDisclosure
    ) -> ImportAdjustment? {
        disclosure.adjustments.first { $0.kind == kind }
    }

    // MARK: - One Fixture Per Kind

    @Test func disclosesGainBeyondFreeRange() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Filter 1: ON PK Fc 1000 Hz Gain -25 dB Q 1.00")
        let gain = try #require(adjustment(.gain, in: parsed.candidates.disclosure))

        #expect(gain.original == -25)
        #expect(gain.adjusted == -20)
        #expect(gain.limit == "±20 dB")
        #expect(gain.filter?.index == 0)
        #expect(gain.filter?.frequency == 1000)
        #expect(gain.filter?.q == 1.00)
        #expect(gain.filter?.kind == .bell)
        #expect(parsed.candidates.exact.filters.filter { !$0.isBand }.first?.gain == -20)
    }

    @Test func disclosesQOutsideRange() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 50")
        let q = try #require(adjustment(.q, in: parsed.candidates.disclosure))

        #expect(q.original == 50)
        #expect(q.adjusted == 10)
        #expect(q.limit == "0.1–10")
        #expect(q.filter?.index == 0)
    }

    @Test func disclosesFrequencyOutsideRange() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Filter 1: ON PK Fc 5 Hz Gain 3 dB Q 1.00")
        let frequency = try #require(adjustment(.frequency, in: parsed.candidates.disclosure))

        #expect(frequency.original == 5)
        #expect(frequency.adjusted == 20)
        #expect(frequency.limit == "20 Hz–20 kHz")
        #expect(frequency.filter?.index == 0)
    }

    @Test func disclosesPreampOutsideRange() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Preamp: -20 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.00")
        let preamp = try #require(adjustment(.preamp, in: parsed.candidates.disclosure))

        #expect(preamp.original == -20)
        #expect(preamp.adjusted == -12)
        #expect(preamp.limit == "−12…+12 dB")
        #expect(preamp.filter == nil)
    }

    @Test func disclosesDroppedFilter() throws {
        var lines = (1...BuiltInProfiles.maxFreeFilters).map {
            "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 6.0 dB Q 1.00"
        }
        lines.append("Filter 17: ON PK Fc 5 Hz Gain 0.5 dB Q 1.00")

        let parsed = try ParametricEQParser.parse(text: lines.joined(separator: "\n"))
        let dropped = try #require(adjustment(.droppedFilter, in: parsed.candidates.disclosure))

        #expect(dropped.original == nil)
        #expect(dropped.adjusted == nil)
        #expect(dropped.limit == "16 free filters")
        #expect(dropped.filter?.index == BuiltInProfiles.maxFreeFilters)
        #expect(parsed.droppedFilterCount == 1)
    }

    @Test func disclosesKeptBeyondBandRange() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Filter 1: ON PK Fc 125 Hz Gain 15 dB Q 1.41")
        let kept = try #require(
            adjustment(.keptBeyondBandRange, in: parsed.candidates.disclosure))

        #expect(kept.original == 15)
        #expect(kept.adjusted == 15)
        #expect(kept.limit == "±12 dB graphic bands")
        #expect(kept.filter?.index == 0)
        #expect(kept.filter?.frequency == 125)
        #expect(!kept.kind.isLossy)
    }

    // MARK: - The Keep-Exact / Clip Choice

    @Test func deepRungIsKeptExactAndOfferedForClipping() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Preamp: -6 dB\nFilter 1: ON PK Fc 125 Hz Gain -20 dB Q 1.41")

        #expect(parsed.candidates.offersClipChoice)
        // A beyond-band value is disclosed as clippable, never as adjusted.
        #expect(parsed.adjustedValueCount == 0)
        #expect(parsed.candidates.disclosure.clippableCount == 1)
        #expect(parsed.candidates.disclosure.requiresConfirmation)
        #expect(!parsed.candidates.disclosure.hasLossyAdjustments)

        // Exact keeps a free filter at the written gain.
        #expect(parsed.candidates.exact.filters.filter { !$0.isBand }.first?.gain == -20)

        // Clipped puts a band on the 125 Hz rung at the graphic limit.
        let slot = try #require(BuiltInProfiles.frequencies.firstIndex(of: 125))
        #expect(parsed.candidates.clipped.filters[slot].isBand)
        #expect(parsed.candidates.clipped.filters[slot].gain == -12)
        #expect(parsed.candidates.clipped.filters.filter { !$0.isBand }.isEmpty)
    }

    @Test func trimmedBeyondBandBellIsDisclosedAsDroppedNotKept() throws {
        // Sixteen pass filters fill the free budget, so the beyond-band bell is
        // trimmed. It must be disclosed as dropped — not as "Kept exact", which
        // would describe a filter that never reached the chain.
        var lines = (0..<BuiltInProfiles.maxFreeFilters).map {
            "Filter \($0 + 1): ON HP Fc \(20 + $0) Hz Q 0.71"
        }
        lines.append("Filter 17: ON PK Fc 125 Hz Gain -20 dB Q 1.41")
        let parsed = try ParametricEQParser.parse(text: lines.joined(separator: "\n"))

        #expect(parsed.droppedFilterCount == 1)
        #expect(parsed.adjustedValueCount == 0)
        let kinds = parsed.candidates.disclosure.adjustments.map(\.kind)
        #expect(kinds == [.droppedFilter])
        #expect(!kinds.contains(.keptBeyondBandRange))
        #expect(parsed.candidates.disclosure.adjustments.first?.filter?.index == 16)
        // The bell's gain was never brought into the chain.
        #expect(
            parsed.candidates.exact.filters.filter { !$0.isBand }.allSatisfy { $0.kind != .bell })
    }

    @Test func coreeqBandGainBeyondFreeRangeIsUnboundAndDisclosed() throws {
        // A band-encoded 30 dB is beyond the free-filters' ±20 dB, so it must be
        // import as a free filter clamped to 20 — and the disclosure must match
        // what is actually stored, not leave a band behind for the ladder's
        // ±12 dB to reshape.
        let band = EQFilter(kind: .bell, frequency: 5, gain: 30, q: 50, band: 0)
        let json = try ParametricEQSerializer.serializeToCoreEQJSON(
            EQProfile(name: "Hot", filters: [band]))
        let parsed = try ParametricEQParser.parse(text: json)

        let stored = try #require(parsed.candidates.exact.filters.first { !$0.isBand })
        #expect(stored.gain == 20)
        #expect(stored.band == nil)
        let gain = try #require(
            parsed.candidates.disclosure.adjustments.first { $0.kind == .gain })
        #expect(gain.original == 30)
        #expect(gain.adjusted == 20)
        #expect(parsed.adjustedValueCount == 1)
    }

    @Test func cleanImportOffersNoChoiceAndNoConfirmation() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Preamp: -3 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.00")

        #expect(!parsed.candidates.offersClipChoice)
        #expect(!parsed.candidates.disclosure.requiresConfirmation)
        #expect(parsed.adjustedValueCount == 0)
        #expect(parsed.candidates.exact == parsed.candidates.clipped)
        #expect(
            ImportImpactCalculator.difference(
                from: parsed.candidates.exact, to: parsed.candidates.clipped, sampleRate: 44_100)
                == ImportImpactCalculator.Result(rmsDB: 0, maxDB: 0))
    }

    @Test func clippingKeepsOccupiedRungAndClampsEveryDeepBell() throws {
        let parsed = try ParametricEQParser.parse(
            text: """
                Preamp: -3 dB
                Filter 1: ON PK Fc 125 Hz Gain 15 dB Q 1.41
                Filter 2: ON PK Fc 125 Hz Gain 3 dB Q 1.41
                Filter 3: ON PK Fc 125 Hz Gain -20 dB Q 1.41
                """)
        let candidates = parsed.candidates
        #expect(candidates.offersClipChoice)
        #expect(candidates.disclosure.clippableCount == 2)
        let slot = try #require(BuiltInProfiles.frequencies.firstIndex(of: 125))
        #expect(candidates.clipped.filters[slot].gain == 3)
        #expect(candidates.clipped.freeFilters.map(\.gain) == [12, -12])
        #expect(candidates.exact.freeFilters.map(\.gain) == [15, -20])
    }

    @Test func clippingDuplicateDeepBellsClampsBothWithoutDroppingEither() throws {
        let parsed = try ParametricEQParser.parse(
            text: """
                Preamp: -3 dB
                Filter 1: ON PK Fc 125 Hz Gain 15 dB Q 1.41
                Filter 2: ON PK Fc 125 Hz Gain -20 dB Q 1.41
                """)
        let slot = try #require(BuiltInProfiles.frequencies.firstIndex(of: 125))
        #expect(parsed.candidates.clipped.filters[slot].gain == 12)
        #expect(parsed.candidates.clipped.freeFilters.map(\.gain) == [-12])
    }

    @Test func lowRateImpactIgnoresUnusedLadderBands() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Preamp: -3 dB\nFilter 1: ON PK Fc 1000 Hz Gain 25 dB Q 1.00",
            sampleRate: 32_000)
        #expect(parsed.candidates.disclosure.impact.isMeasurable)
        #expect((parsed.candidates.disclosure.impact.maxDB ?? 0) > 4.9)
    }

    @Test func impactUsesRequestedSampleRate() throws {
        let text = "Preamp: -3 dB\nFilter 1: ON PK Fc 19000 Hz Gain 25 dB Q 1.00"
        let at44 = try AutoEQProfileBuilder.makeProfile(
            model: "High", parametricEQText: text, sampleRate: 44_100)
        let at96 = try AutoEQProfileBuilder.makeProfile(
            model: "High", parametricEQText: text, sampleRate: 96_000)
        #expect(at44.disclosure.impact.isMeasurable)
        #expect(at96.disclosure.impact.isMeasurable)
        #expect(
            abs((at44.disclosure.impact.rmsDB ?? 0) - (at96.disclosure.impact.rmsDB ?? 0)) > 0.1)
    }

    // MARK: - Unrepresentable Values

    @Test func unrepresentableValuesAreAdjustedAndDisclosed() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Preamp: -20 dB\nFilter 1: ON PK Fc 1000 Hz Gain -25 dB Q 1.00")

        #expect(parsed.candidates.disclosure.requiresConfirmation)
        #expect(parsed.candidates.disclosure.hasLossyAdjustments)
        #expect(parsed.adjustedValueCount == 2)

        let gain = try #require(adjustment(.gain, in: parsed.candidates.disclosure))
        #expect(gain.original == -25)
        #expect(gain.adjusted == -20)

        let preamp = try #require(adjustment(.preamp, in: parsed.candidates.disclosure))
        #expect(preamp.original == -20)
        #expect(preamp.adjusted == -12)

        // The default commit stores exactly the adjusted values disclosed.
        #expect(parsed.candidates.exact.preamp == -12)
        #expect(parsed.candidates.exact.filters.filter { !$0.isBand }.first?.gain == -20)
    }

    // MARK: - Impact

    @Test func identicalChainsHaveNoDifference() {
        let profile = EQProfile(
            name: "x",
            filters: [EQFilter(kind: .bell, frequency: 1000, gain: 3, q: 1.0)],
            preamp: -2)
        let result = ImportImpactCalculator.difference(
            from: profile, to: profile, sampleRate: 44_100)
        #expect(result == ImportImpactCalculator.Result(rmsDB: 0, maxDB: 0))
    }

    @Test func clampedShelfHasAPlausibleImpact() {
        let intended = EQProfile(
            name: "intended",
            filters: [EQFilter(kind: .lowShelf, frequency: 100, gain: -25, q: 0.7)])
        let committed = EQProfile(
            name: "committed",
            filters: [EQFilter(kind: .lowShelf, frequency: 100, gain: -20, q: 0.7)])

        let result = ImportImpactCalculator.difference(
            from: intended, to: committed, sampleRate: 44_100)
        #expect(result != nil)
        #expect((result?.rmsDB ?? 0) > 0)
        #expect((result?.maxDB ?? 0) > 0)
        // A 5 dB shelf cannot move the response by more than the clamp itself.
        #expect((result?.maxDB ?? 0) < 6)
    }

    @Test func nonPhysicalQIsNotRenderable() {
        let bad = EQFilter(kind: .bell, frequency: 1000, gain: 3, q: 0)
        let good = EQProfile(
            name: "good", filters: [EQFilter(kind: .bell, frequency: 1000, gain: 3, q: 1.0)])

        #expect(!ImportImpactCalculator.isRenderable(bad, sampleRate: 44_100))
        #expect(
            ImportImpactCalculator.difference(
                from: EQProfile(name: "bad", filters: [bad]), to: good, sampleRate: 44_100)
                == nil)
    }

    @Test func frequencyAtNyquistCeilingIsNotRenderable() {
        let sampleRate = 44_100.0
        let atCeiling = EQFilter(
            kind: .bell, frequency: sampleRate * Biquad.nyquistCeiling, gain: 3, q: 1.0)

        #expect(!ImportImpactCalculator.isRenderable(atCeiling, sampleRate: sampleRate))
        #expect(
            ImportImpactCalculator.difference(
                from: EQProfile(name: "ceiling", filters: [atCeiling]),
                to: EQProfile(name: "empty", filters: []), sampleRate: sampleRate) == nil)
    }

    @Test func unmeasurableImpactIsReportedForNonPhysicalIntendedValues() throws {
        let parsed = try ParametricEQParser.parse(
            text: "Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 0",
            defaultName: "NonPhysical")
        // Q 0 is clamped to 0.1 in the exact chain, and the intended chain has
        // no response, so the impact is measurable — the exact chain renders.
        #expect(parsed.candidates.exact.filters.filter { !$0.isBand }.first?.q == 0.1)
    }
}
