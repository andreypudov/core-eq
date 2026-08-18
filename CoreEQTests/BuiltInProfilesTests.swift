import Foundation
import Testing

struct BuiltInProfilesTests {
    @Test(arguments: BuiltInProfiles.all) func everyProfileMatchesTheBandLadder(profile: EQProfile)
    {
        #expect(
            profile.bandFilters.map(\.frequency) == BuiltInProfiles.frequencies,
            "\(profile.name) does not sit on the shared band ladder")
    }

    /// A preset may carry filters, but never many: each is a pass over every
    /// buffer, and each one a preset spends is one the user cannot.
    @Test(arguments: BuiltInProfiles.all) func builtInProfilesCarryAtMostAFilterOrTwo(
        profile: EQProfile
    ) {
        #expect(
            profile.freeFilters.count <= 2,
            "\(profile.name) ships with more filters than a preset should need")
        #expect(
            profile.filters.count == BuiltInProfiles.bandCount + profile.freeFilters.count,
            "\(profile.name) is not the ladder followed by its filters")
        for filter in profile.freeFilters {
            #expect(BuiltInProfiles.filterFrequencyRange.contains(filter.frequency))
            #expect(BuiltInProfiles.filterQRange.contains(filter.q))
            #expect(BuiltInProfiles.gainRange.contains(filter.gain))
        }
    }

    /// The rule that keeps the Graphic tab honest: strip a preset's filters and
    /// the eleven sliders must still describe that preset. A filter refines the
    /// shape — it never carries it, or the sliders would sit flat under a curve
    /// that is anything but, and dragging one would move the sound relative to
    /// a baseline nobody can see.
    ///
    /// Measured where the ladder is authoritative: at its own rungs. Below the
    /// lowest and above the highest, a shelf is *supposed* to be doing what the
    /// bells cannot.
    @Test(arguments: BuiltInProfiles.all.filter { !$0.freeFilters.isEmpty })
    func theLadderCarriesEveryPreset(profile: EQProfile) {
        let rate = 48_000.0
        for frequency in BuiltInProfiles.frequencies {
            let whole = response(profile.filters, at: frequency, rate: rate)
            let ladder = response(profile.bandFilters, at: frequency, rate: rate)
            guard abs(whole) > 3 else { continue }

            #expect(
                ladder.sign == whole.sign,
                "\(profile.name): the sliders point the other way to the curve at \(frequency) Hz"
            )
            #expect(
                abs(ladder) > abs(whole) * 0.4,
                """
                \(profile.name) at \(frequency) Hz: the curve is \(whole) dB but the sliders \
                alone are \(ladder) dB — the filter is carrying the preset rather than refining it
                """)
        }
    }

    private func response(_ filters: [EQFilter], at frequency: Double, rate: Double) -> Double {
        filters.reduce(0.0) {
            $0 + Biquad(filter: $1, sampleRate: rate).magnitudeDB(at: frequency, sampleRate: rate)
        }
    }

    @Test(arguments: BuiltInProfiles.all) func everyBandCarriesItsLadderSlot(profile: EQProfile) {
        #expect(
            profile.bandFilters.map(\.band) == Array(0..<BuiltInProfiles.bandCount),
            "\(profile.name) has bands out of slot order")
    }

    @Test(arguments: BuiltInProfiles.all) func everyGainIsWithinRange(profile: EQProfile) {
        for band in profile.bandFilters {
            #expect(
                BuiltInProfiles.gainRange.contains(band.gain),
                "\(profile.name) at \(band.frequency) Hz is \(band.gain) dB, outside the slider range"
            )
        }
    }

    @Test func namesAreUnique() {
        let names = BuiltInProfiles.all.map(\.name)
        #expect(
            Set(names).count == names.count,
            "built-in profile names must be unique — they are the identifiers")
    }

    @Test func flatIsFlatAndIsTheDefault() {
        let flat = BuiltInProfiles.all.first { $0.name == BuiltInProfiles.defaultProfileName }
        #expect(flat != nil)
        #expect(flat?.name == "Flat")
        #expect(flat?.filters.allSatisfy { $0.gain == 0 } ?? false)
    }

    @Test func allProfilesAreMarkedBuiltIn() {
        #expect(BuiltInProfiles.all.allSatisfy { $0.isBuiltIn })
    }

    @Test func ladderIsAscending() {
        #expect(BuiltInProfiles.frequencies == BuiltInProfiles.frequencies.sorted())
    }

    /// `isBuiltIn` is deliberately outside `CodingKeys`, because only user
    /// profiles are ever persisted.
    @Test func roundTripDecodingYieldsAUserProfile() throws {
        let original = BuiltInProfiles.all[1]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EQProfile.self, from: data)

        #expect(decoded.name == original.name)
        #expect(decoded.filters == original.filters)
        #expect(!decoded.isBuiltIn, "a decoded profile is always a user profile")
    }

    /// `EQFilter.id` is outside both `CodingKeys` and `==`, so a chain restored
    /// from disk compares equal to the one it was saved from. Without this,
    /// `ProfileManager.isModified` would report every launch as edited.
    @Test func decodedFiltersCompareEqualDespiteFreshIdentifiers() throws {
        let original = BuiltInProfiles.all[3].filters
        let decoded = try JSONDecoder().decode(
            [EQFilter].self, from: JSONEncoder().encode(original))

        #expect(decoded == original)
        #expect(decoded.map(\.id) != original.map(\.id))
    }

    /// Presets written by CoreEQ 1.x stored a `bands` array with no kind, no
    /// enabled flag, and no slot. They have to keep working.
    @Test func legacyBandsPresetMigratesIntoLadderFilters() throws {
        let legacy = """
            {"name":"Old","bands":[
              {"frequency":32,"gain":4,"q":1.41},
              {"frequency":64,"gain":-2,"q":1.41}
            ]}
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(EQProfile.self, from: legacy)
        #expect(decoded.name == "Old")
        #expect(decoded.filters.count == 2)
        #expect(decoded.filters.map(\.band) == [0, 1])
        #expect(decoded.filters.map(\.gain) == [4, -2])
        #expect(decoded.filters.allSatisfy { $0.kind == .bell && $0.isEnabled })
    }
}

extension Double {
    /// -1, 0, or +1 — for comparing which way two curves point.
    fileprivate var sign: Int { self == 0 ? 0 : (self < 0 ? -1 : 1) }
}
