import XCTest

/// The preset collection, exercised without a manager, a defaults suite, or a
/// main actor — which is the point of it being a value type.
final class PresetLibraryTests: XCTestCase {
    private func profile(_ name: String, gain: Double = 0) -> EQProfile {
        var chain = BuiltInProfiles.emptyBandChain()
        for slot in chain.indices { chain[slot].gain = gain }
        return EQProfile(name: name, filters: chain)
    }

    // MARK: - Building one

    func testAFreshLibraryIsTheBuiltInsAndNothingElse() {
        let library = PresetLibrary()
        XCTAssertEqual(library.builtIn.count, BuiltInProfiles.all.count)
        XCTAssertTrue(library.user.isEmpty)
        XCTAssertEqual(library.all.count, BuiltInProfiles.all.count)
    }

    /// Built-ins first is the order the sidebar and the menu both present.
    func testBuiltInsComeBeforeTheUsersOwn() {
        let library = PresetLibrary(stored: [profile("Mine")])
        XCTAssertEqual(library.all.first?.name, BuiltInProfiles.all[0].name)
        XCTAssertEqual(library.all.last?.name, "Mine")
    }

    /// Names are identity — every device's stored state refers to a preset by
    /// name — so a duplicate is two rows that cannot be told apart.
    func testAStoredPresetCollidingWithABuiltInIsDropped() {
        let library = PresetLibrary(stored: [profile("Jazz"), profile("Mine")])
        XCTAssertEqual(library.user.map(\.name), ["Mine"])
    }

    func testTwoStoredPresetsWithOneNameKeepTheFirst() {
        let library = PresetLibrary(stored: [profile("Mine", gain: 3), profile("Mine", gain: -3)])
        XCTAssertEqual(library.user.count, 1)
        XCTAssertEqual(library.user[0].bandFilters[0].gain, 3)
    }

    /// A stored chain is normalised on the way in, so the slider strip can index
    /// straight into it however it was written.
    func testStoredChainsAreNormalised() {
        let short = EQProfile(name: "Short", filters: [EQFilter.band(slot: 0, gain: 2)])
        let library = PresetLibrary(stored: [short])
        XCTAssertEqual(library.user[0].filters.count, BuiltInProfiles.bandCount)
        XCTAssertEqual(library.user[0].bandFilters[0].gain, 2)
    }

    // MARK: - Naming

    func testNamesAreMadeUnique() {
        var library = PresetLibrary()
        XCTAssertEqual(library.add(profile("Mine")), "Mine")
        XCTAssertEqual(library.add(profile("Mine")), "Mine 2")
        XCTAssertEqual(library.add(profile("Mine")), "Mine 3")
    }

    func testANewNameCannotCollideWithABuiltIn() {
        var library = PresetLibrary()
        XCTAssertEqual(library.add(profile("Rock")), "Rock 2")
    }

    func testAnAddedPresetIsNeverBuiltIn() {
        var library = PresetLibrary()
        let name = library.add(EQProfile(name: "Copy", filters: [], isBuiltIn: true))
        XCTAssertEqual(library.profile(named: name)?.isBuiltIn, false)
    }

    // MARK: - Renaming

    func testRenamingReturnsTheNameItTook() {
        var library = PresetLibrary(stored: [profile("Before")])
        XCTAssertEqual(library.rename("Before", to: "After"), "After")
        XCTAssertEqual(library.user.map(\.name), ["After"])
    }

    func testRenamingRefusesEmptyNamesAndBuiltIns() {
        var library = PresetLibrary(stored: [profile("Mine")])
        XCTAssertNil(library.rename("Mine", to: "   "))
        XCTAssertNil(library.rename("Mine", to: "Mine"), "renaming to the same name is not a rename")
        XCTAssertNil(library.rename("Jazz", to: "Anything"), "a built-in cannot be renamed")
        XCTAssertEqual(library.user.map(\.name), ["Mine"])
    }

    func testRenamingIntoACollisionGetsASuffix() {
        var library = PresetLibrary(stored: [profile("One"), profile("Two")])
        XCTAssertEqual(library.rename("Two", to: "One"), "One 2")
    }

    // MARK: - Removing

    /// What the sidebar should select next, so a deletion never leaves nothing
    /// playing.
    func testRemovingReportsWhatToSelectNext() {
        var library = PresetLibrary(stored: [profile("A"), profile("B"), profile("C")])

        XCTAssertEqual(library.remove("B"), "C", "the preset that took its place")
        XCTAssertEqual(library.remove("C"), "A", "the one before it, when there is no next")
        XCTAssertEqual(library.remove("A"), BuiltInProfiles.defaultProfileName, "the default, when none is left")
    }

    func testRemovingSomethingThatIsNotThereChangesNothing() {
        var library = PresetLibrary(stored: [profile("Mine")])
        XCTAssertNil(library.remove("Jazz"), "a built-in cannot be removed")
        XCTAssertNil(library.remove("Nothing"))
        XCTAssertEqual(library.user.count, 1)
    }

    // MARK: - Updating

    func testUpdatingWritesTheSoundIntoAUserPreset() {
        var library = PresetLibrary(stored: [profile("Mine")])
        var chain = BuiltInProfiles.emptyBandChain()
        chain[4].gain = 7

        library.update("Mine", filters: chain, preamp: -2, autoGain: true)

        let saved = library.profile(named: "Mine")
        XCTAssertEqual(saved?.bandFilters[4].gain, 7)
        XCTAssertEqual(saved?.preamp, -2)
        XCTAssertEqual(saved?.autoGain, true)
    }

    func testUpdatingABuiltInDoesNothing() {
        var library = PresetLibrary()
        let before = library.profile(named: "Jazz")
        library.update("Jazz", filters: BuiltInProfiles.emptyBandChain(), preamp: 5, autoGain: true)
        XCTAssertEqual(library.profile(named: "Jazz"), before, "that is what makes them built in")
    }

    // MARK: - Looking things up

    func testLookupAndEditability() {
        let library = PresetLibrary(stored: [profile("Mine")])
        XCTAssertEqual(library.profile(named: "Jazz")?.name, "Jazz")
        XCTAssertEqual(library.profile(named: "Mine")?.name, "Mine")
        XCTAssertNil(library.profile(named: "Missing"))

        XCTAssertTrue(library.isEditable("Mine"))
        XCTAssertFalse(library.isEditable("Jazz"))
    }
}
