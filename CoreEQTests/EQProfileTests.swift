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

final class QuickToneTests: XCTestCase {
    func testWeightsCoverEveryBand() {
        let count = BuiltInProfiles.frequencies.count
        XCTAssertEqual(QuickTone.bassWeights.count, count)
        XCTAssertEqual(QuickTone.midWeights.count, count)
        XCTAssertEqual(QuickTone.trebleWeights.count, count)
    }

    func testNeutralControlsProduceNoOffset() {
        XCTAssertTrue(QuickTone.offsets(bass: 0, mid: 0, treble: 0).allSatisfy { $0 == 0 })
    }

    func testBassOnlyLiftsTheLowEnd() {
        let offsets = QuickTone.offsets(bass: 6, mid: 0, treble: 0)
        let frequencies = BuiltInProfiles.frequencies

        let lowest = offsets[frequencies.firstIndex(of: 32)!]
        let highest = offsets[frequencies.firstIndex(of: 20_000)!]
        XCTAssertGreaterThan(lowest, 0)
        XCTAssertEqual(highest, 0, "a bass control must not touch 20 kHz")
    }

    func testTrebleOnlyLiftsTheTopEnd() {
        let offsets = QuickTone.offsets(bass: 0, mid: 0, treble: 6)
        let frequencies = BuiltInProfiles.frequencies

        XCTAssertEqual(offsets[frequencies.firstIndex(of: 32)!], 0, "a treble control must not touch 32 Hz")
        XCTAssertGreaterThan(offsets[frequencies.firstIndex(of: 20_000)!], 0)
    }

    func testOffsetsAreAdditive() {
        let combined = QuickTone.offsets(bass: 4, mid: 2, treble: -3)
        let separate = zip(
            zip(QuickTone.offsets(bass: 4, mid: 0, treble: 0), QuickTone.offsets(bass: 0, mid: 2, treble: 0)).map(+),
            QuickTone.offsets(bass: 0, mid: 0, treble: -3)
        ).map(+)

        for (lhs, rhs) in zip(combined, separate) {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-12)
        }
    }
}
