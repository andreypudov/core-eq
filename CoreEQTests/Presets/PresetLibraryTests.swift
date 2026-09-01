import Foundation
import Testing

/// The preset collection, exercised without a manager, a defaults suite, or a
/// main actor — which is the point of it being a value type.
struct PresetLibraryTests {
    private func profile(_ name: String, gain: Double = 0) -> EQProfile {
        var chain = BuiltInProfiles.emptyBandChain()
        for slot in chain.indices { chain[slot].gain = gain }
        return EQProfile(name: name, filters: chain)
    }

    // MARK: - Building one

    @Test func aFreshLibraryIsTheBuiltInsAndNothingElse() {
        let library = PresetLibrary()
        #expect(library.builtIn.count == BuiltInProfiles.all.count)
        #expect(library.user.isEmpty)
        #expect(library.all.count == BuiltInProfiles.all.count)
    }

    /// Built-ins first is the order the sidebar and the menu both present.
    @Test func builtInsComeBeforeTheUsersOwn() {
        let library = PresetLibrary(stored: [profile("Mine")])
        #expect(library.all.first?.name == BuiltInProfiles.all[0].name)
        #expect(library.all.last?.name == "Mine")
    }

    /// Names are identity — every device's stored state refers to a preset by
    /// name — so a duplicate is two rows that cannot be told apart.
    @Test func aStoredPresetCollidingWithABuiltInIsDropped() {
        let library = PresetLibrary(stored: [profile("Jazz"), profile("Mine")])
        #expect(library.user.map(\.name) == ["Mine"])
    }

    @Test func twoStoredPresetsWithOneNameKeepTheFirst() {
        let library = PresetLibrary(stored: [profile("Mine", gain: 3), profile("Mine", gain: -3)])
        #expect(library.user.count == 1)
        #expect(library.user[0].bandFilters[0].gain == 3)
    }

    /// A stored chain is normalised on the way in, so the slider strip can index
    /// straight into it however it was written.
    @Test func storedChainsAreNormalised() {
        let short = EQProfile(name: "Short", filters: [EQFilter.band(slot: 0, gain: 2)])
        let library = PresetLibrary(stored: [short])
        #expect(library.user[0].filters.count == BuiltInProfiles.bandCount)
        #expect(library.user[0].bandFilters[0].gain == 2)
    }

    // MARK: - Naming

    @Test func namesAreMadeUnique() {
        var library = PresetLibrary()
        #expect(library.add(profile("Mine")) == "Mine")
        #expect(library.add(profile("Mine")) == "Mine 2")
        #expect(library.add(profile("Mine")) == "Mine 3")
    }

    @Test func aNewNameCannotCollideWithABuiltIn() {
        var library = PresetLibrary()
        #expect(library.add(profile("Rock")) == "Rock 2")
    }

    @Test func anAddedPresetIsNeverBuiltIn() {
        var library = PresetLibrary()
        let name = library.add(EQProfile(name: "Copy", filters: [], isBuiltIn: true))
        #expect(library.profile(named: name)?.isBuiltIn == false)
    }

    // MARK: - Renaming

    @Test func renamingReturnsTheNameItTook() {
        var library = PresetLibrary(stored: [profile("Before")])
        #expect(library.rename("Before", to: "After") == "After")
        #expect(library.user.map(\.name) == ["After"])
    }

    @Test func renamingRefusesEmptyNamesAndBuiltIns() {
        var library = PresetLibrary(stored: [profile("Mine")])
        #expect(library.rename("Mine", to: "   ") == nil)
        #expect(
            library.rename("Mine", to: "Mine") == nil, "renaming to the same name is not a rename")
        #expect(library.rename("Jazz", to: "Anything") == nil, "a built-in cannot be renamed")
        #expect(library.user.map(\.name) == ["Mine"])
    }

    @Test func renamingIntoACollisionGetsASuffix() {
        var library = PresetLibrary(stored: [profile("One"), profile("Two")])
        #expect(library.rename("Two", to: "One") == "One 2")
    }

    // MARK: - Removing

    /// What the sidebar should select next, so a deletion never leaves nothing
    /// playing.
    @Test func removingReportsWhatToSelectNext() {
        var library = PresetLibrary(stored: [profile("A"), profile("B"), profile("C")])

        #expect(library.remove("B") == "C", "the preset that took its place")
        #expect(library.remove("C") == "A", "the one before it, when there is no next")
        #expect(
            library.remove("A") == BuiltInProfiles.defaultProfileName,
            "the default, when none is left")
    }

    @Test func removingSomethingThatIsNotThereChangesNothing() {
        var library = PresetLibrary(stored: [profile("Mine")])
        #expect(library.remove("Jazz") == nil, "a built-in cannot be removed")
        #expect(library.remove("Nothing") == nil)
        #expect(library.user.count == 1)
    }

    // MARK: - Updating

    @Test func updatingWritesTheSoundIntoAUserPreset() {
        var library = PresetLibrary(stored: [profile("Mine")])
        var chain = BuiltInProfiles.emptyBandChain()
        chain[4].gain = 7

        library.update("Mine", filters: chain, preamp: -2, autoGain: true)

        let saved = library.profile(named: "Mine")
        #expect(saved?.bandFilters[4].gain == 7)
        #expect(saved?.preamp == -2)
        #expect(saved?.autoGain == true)
    }

    @Test func updatingABuiltInDoesNothing() {
        var library = PresetLibrary()
        let before = library.profile(named: "Jazz")
        library.update("Jazz", filters: BuiltInProfiles.emptyBandChain(), preamp: 5, autoGain: true)
        #expect(library.profile(named: "Jazz") == before, "that is what makes them built in")
    }

    // MARK: - Looking things up

    @Test func lookupAndEditability() {
        let library = PresetLibrary(stored: [profile("Mine")])
        #expect(library.profile(named: "Jazz")?.name == "Jazz")
        #expect(library.profile(named: "Mine")?.name == "Mine")
        #expect(library.profile(named: "Missing") == nil)

        #expect(library.isEditable("Mine"))
        #expect(!library.isEditable("Jazz"))
    }
}
