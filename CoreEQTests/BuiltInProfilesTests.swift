import XCTest

final class BuiltInProfilesTests: XCTestCase {
    func testEveryProfileMatchesTheBandLadder() {
        for profile in BuiltInProfiles.all {
            XCTAssertEqual(
                profile.bands.map(\.frequency), BuiltInProfiles.frequencies,
                "\(profile.name) does not sit on the shared band ladder"
            )
        }
    }

    func testEveryGainIsWithinRange() {
        for profile in BuiltInProfiles.all {
            for band in profile.bands {
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
        XCTAssertTrue(flat?.bands.allSatisfy { $0.gain == 0 } ?? false)
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
        XCTAssertEqual(decoded.bands, original.bands)
        XCTAssertFalse(decoded.isBuiltIn, "a decoded profile is always a user profile")
    }
}
