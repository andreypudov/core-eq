import XCTest

/// A preset and a device's slot are the two things written to disk. Everything
/// a user builds lives or dies by these round trips.
final class EQProfileTests: XCTestCase {
    private func chain(bandGain: Double = 0, free: [EQFilter] = []) -> [EQFilter] {
        var bands = BuiltInProfiles.emptyBandChain()
        for slot in bands.indices { bands[slot].gain = bandGain }
        return bands + free
    }

    // MARK: - Reading a chain

    func testAProfileSplitsItsChainIntoBandsAndFilters() {
        let free = EQFilter(kind: .bell, frequency: 2_800, gain: 2, q: 1.2)
        let profile = EQProfile(name: "Test", filters: chain(bandGain: 1, free: [free]))

        XCTAssertEqual(profile.bandFilters.count, BuiltInProfiles.bandCount)
        XCTAssertEqual(profile.bandFilters.map(\.band), Array(0..<BuiltInProfiles.bandCount))
        XCTAssertEqual(profile.freeFilters.count, 1)
        XCTAssertEqual(profile.freeFilters.first?.frequency, 2_800)
    }

    /// The bands come back in slot order however they were stored, because the
    /// slider strip indexes straight into them.
    func testBandsComeBackInSlotOrder() {
        let scrambled = BuiltInProfiles.emptyBandChain().reversed()
        let profile = EQProfile(name: "Test", filters: Array(scrambled))

        XCTAssertEqual(profile.bandFilters.map(\.band), Array(0..<BuiltInProfiles.bandCount))
    }

    /// Identity is the name — the sidebar, the menu, and every device's stored
    /// state all refer to a preset by it.
    func testAProfileIsIdentifiedByItsName() {
        XCTAssertEqual(EQProfile(name: "Rock", filters: []).id, "Rock")
    }

    // MARK: - Coding

    func testCodingRoundTrip() throws {
        let profile = EQProfile(
            name: "Late Night",
            filters: chain(
                bandGain: 2,
                free: [
                    EQFilter(kind: .lowShelf, frequency: 120, gain: -3, q: 0.7, colorIndex: 3)
                ]),
            preamp: -1.5
        )
        let decoded = try JSONDecoder().decode(
            EQProfile.self, from: JSONEncoder().encode(profile)
        )

        XCTAssertEqual(decoded.name, profile.name)
        XCTAssertEqual(decoded.filters, profile.filters)
        XCTAssertEqual(decoded.preamp, profile.preamp)
    }

    /// Only user profiles are ever written, so a decoded one is a user profile
    /// — otherwise a stored copy of a built-in would come back unrenameable and
    /// undeletable.
    func testADecodedProfileIsAUserProfile() throws {
        let builtIn = BuiltInProfiles.all[1]
        XCTAssertTrue(builtIn.isBuiltIn)

        let decoded = try JSONDecoder().decode(
            EQProfile.self, from: JSONEncoder().encode(builtIn)
        )
        XCTAssertFalse(decoded.isBuiltIn)
    }

    func testAProfileWithoutAPreampDecodesAsUntrimmed() throws {
        let json = Data(#"{"name": "Old", "filters": []}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EQProfile.self, from: json).preamp, 0)
    }

    /// Presets written by CoreEQ 1.x are a flat array of bands with no kind, no
    /// enabled flag, and no slot. They have to open, or an update looks like it
    /// deleted the user's presets.
    func testAPresetFromTheBandEraStillOpens() throws {
        let json = Data(
            """
            {"name": "From 1.x", "bands": [
                {"frequency": 32, "gain": 4, "q": 1.41},
                {"frequency": 64, "gain": -2, "q": 1.41}
            ]}
            """.utf8)
        let decoded = try JSONDecoder().decode(EQProfile.self, from: json)

        XCTAssertEqual(decoded.name, "From 1.x")
        XCTAssertEqual(decoded.filters.count, 2)
        XCTAssertEqual(
            decoded.filters.map(\.band), [0, 1],
            "old bands take slots in the order they were stored")
        XCTAssertEqual(decoded.filters.map(\.gain), [4, -2])
        XCTAssertTrue(decoded.filters.allSatisfy { $0.kind == .bell && $0.isEnabled })
    }
}

/// The per-device slot: which preset is playing on this output, what has been
/// changed about it, and the tone positions.
final class DeviceEQStateTests: XCTestCase {
    func testCodingRoundTrip() throws {
        var chain = BuiltInProfiles.emptyBandChain()
        chain[4].gain = -3

        let state = DeviceEQState(
            profileName: "Jazz", filters: chain, preamp: 2, tone: [1, -1, 0.5])
        let decoded = try JSONDecoder().decode(
            DeviceEQState.self, from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.filters?[4].gain, -3)
        XCTAssertEqual(decoded.tone, [1, -1, 0.5])
    }

    /// An unedited device stores a preset name and nothing else — the two nils
    /// are what "no unsaved changes, tone centred" looks like on disk.
    func testAnUneditedDeviceStoresAlmostNothing() throws {
        let state = DeviceEQState(profileName: "Flat")

        XCTAssertNil(state.filters)
        XCTAssertNil(state.tone)
        XCTAssertEqual(state.preamp, 0)

        let decoded = try JSONDecoder().decode(
            DeviceEQState.self, from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded, state)
    }
}
