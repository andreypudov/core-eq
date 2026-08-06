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

    /// A built-in preset is the ladder and nothing else, which is what makes
    /// selecting one a complete description of a sound rather than a partial
    /// one layered over whatever came before.
    func testBuiltInProfilesCarryNoFreeFilters() {
        for profile in BuiltInProfiles.all {
            XCTAssertTrue(
                profile.freeFilters.isEmpty,
                "\(profile.name) ships with a free filter"
            )
            XCTAssertEqual(profile.filters.count, BuiltInProfiles.bandCount)
        }
    }

    func testEveryBandCarriesItsLadderSlot() {
        for profile in BuiltInProfiles.all {
            XCTAssertEqual(
                profile.filters.map(\.band), Array(0..<BuiltInProfiles.bandCount),
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
