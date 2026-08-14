import XCTest

final class BuiltInProfilesTests: XCTestCase {
    func testEveryProfileMatchesTheBandLadder() {
        for profile in BuiltInProfiles.all {
            XCTAssertEqual(
                profile.bandFilters.map(\.frequency), BuiltInProfiles.frequencies,
                "\(profile.name) does not sit on the shared band ladder"
            )
        }
    }

    /// A preset may carry filters, but never many: each is a pass over every
    /// buffer, and each one a preset spends is one the user cannot.
    func testBuiltInProfilesCarryAtMostAFilterOrTwo() {
        for profile in BuiltInProfiles.all {
            XCTAssertLessThanOrEqual(
                profile.freeFilters.count, 2,
                "\(profile.name) ships with more filters than a preset should need"
            )
            XCTAssertEqual(
                profile.filters.count, BuiltInProfiles.bandCount + profile.freeFilters.count,
                "\(profile.name) is not the ladder followed by its filters"
            )
            for filter in profile.freeFilters {
                XCTAssertTrue(BuiltInProfiles.filterFrequencyRange.contains(filter.frequency))
                XCTAssertTrue(BuiltInProfiles.filterQRange.contains(filter.q))
                XCTAssertTrue(BuiltInProfiles.gainRange.contains(filter.gain))
            }
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
    func testTheLadderCarriesEveryPreset() {
        let rate = 48_000.0
        for profile in BuiltInProfiles.all where !profile.freeFilters.isEmpty {
            for frequency in BuiltInProfiles.frequencies {
                let whole = response(profile.filters, at: frequency, rate: rate)
                let ladder = response(profile.bandFilters, at: frequency, rate: rate)
                guard abs(whole) > 3 else { continue }

                XCTAssertEqual(
                    ladder.sign, whole.sign,
                    "\(profile.name): the sliders point the other way to the curve at \(frequency) Hz"
                )
                XCTAssertGreaterThan(
                    abs(ladder), abs(whole) * 0.4,
                    """
                    \(profile.name) at \(frequency) Hz: the curve is \(whole) dB but the sliders alone                     are \(ladder) dB — the filter is carrying the preset rather than refining it
                    """
                )
            }
        }
    }

    private func response(_ filters: [EQFilter], at frequency: Double, rate: Double) -> Double {
        filters.reduce(0.0) {
            $0 + Biquad(filter: $1, sampleRate: rate).magnitudeDB(at: frequency, sampleRate: rate)
        }
    }

    func testEveryBandCarriesItsLadderSlot() {
        for profile in BuiltInProfiles.all {
            XCTAssertEqual(
                profile.bandFilters.map(\.band), Array(0..<BuiltInProfiles.bandCount),
                "\(profile.name) has bands out of slot order"
            )
        }
    }

    func testEveryGainIsWithinRange() {
        for profile in BuiltInProfiles.all {
            for band in profile.bandFilters {
                XCTAssertTrue(
                    BuiltInProfiles.gainRange.contains(band.gain),
                    "\(profile.name) at \(band.frequency) Hz is \(band.gain) dB, outside the slider range"
                )
            }
        }
    }

    func testNamesAreUnique() {
        let names = BuiltInProfiles.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "built-in profile names must be unique — they are the identifiers")
    }

    func testFlatIsFlatAndIsTheDefault() {
        let flat = BuiltInProfiles.all.first { $0.name == BuiltInProfiles.defaultProfileName }
        XCTAssertNotNil(flat)
        XCTAssertEqual(flat?.name, "Flat")
        XCTAssertTrue(flat?.filters.allSatisfy { $0.gain == 0 } ?? false)
    }

    func testAllProfilesAreMarkedBuiltIn() {
        XCTAssertTrue(BuiltInProfiles.all.allSatisfy(\.isBuiltIn))
    }

    func testLadderIsAscending() {
        XCTAssertEqual(BuiltInProfiles.frequencies, BuiltInProfiles.frequencies.sorted())
    }

    /// `isBuiltIn` is deliberately outside `CodingKeys`, because only user
    /// profiles are ever persisted.
    func testRoundTripDecodingYieldsAUserProfile() throws {
        let original = BuiltInProfiles.all[1]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EQProfile.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.filters, original.filters)
        XCTAssertFalse(decoded.isBuiltIn, "a decoded profile is always a user profile")
    }

    /// `EQFilter.id` is outside both `CodingKeys` and `==`, so a chain restored
    /// from disk compares equal to the one it was saved from. Without this,
    /// `ProfileManager.isModified` would report every launch as edited.
    func testDecodedFiltersCompareEqualDespiteFreshIdentifiers() throws {
        let original = BuiltInProfiles.all[3].filters
        let decoded = try JSONDecoder().decode([EQFilter].self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertNotEqual(decoded.map(\.id), original.map(\.id))
    }

    /// Presets written by CoreEQ 1.x stored a `bands` array with no kind, no
    /// enabled flag, and no slot. They have to keep working.
    func testLegacyBandsPresetMigratesIntoLadderFilters() throws {
        let legacy = """
        {"name":"Old","bands":[
          {"frequency":32,"gain":4,"q":1.41},
          {"frequency":64,"gain":-2,"q":1.41}
        ]}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(EQProfile.self, from: legacy)
        XCTAssertEqual(decoded.name, "Old")
        XCTAssertEqual(decoded.filters.count, 2)
        XCTAssertEqual(decoded.filters.map(\.band), [0, 1])
        XCTAssertEqual(decoded.filters.map(\.gain), [4, -2])
        XCTAssertTrue(decoded.filters.allSatisfy { $0.kind == .bell && $0.isEnabled })
    }
}

extension Double {
    /// -1, 0, or +1 — for comparing which way two curves point.
    fileprivate var sign: Int { self == 0 ? 0 : (self < 0 ? -1 : 1) }
}
