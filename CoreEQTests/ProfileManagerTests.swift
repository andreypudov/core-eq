import XCTest

@MainActor
final class ProfileManagerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUp() {
        super.setUp()
        // A throwaway suite per test, so these never touch the real app's state.
        suiteName = "coreeq.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        super.tearDown()
    }

    private func makeManager() -> ProfileManager {
        ProfileManager(settings: settings)
    }

    /// Total response of a chain at `frequency`, the way the graph and the
    /// slider tick compute it.
    private func total(_ filters: [EQFilter], at frequency: Double, sampleRate: Double = 48_000) -> Double {
        filters.reduce(0.0) {
            $0 + Biquad(filter: $1, sampleRate: sampleRate).magnitudeDB(at: frequency, sampleRate: sampleRate)
        }
    }

    // MARK: - Launch state

    func testStartsOnTheDefaultProfile() {
        let manager = makeManager()
        XCTAssertEqual(manager.activeProfileName, BuiltInProfiles.defaultProfileName)
        XCTAssertFalse(manager.isModified)
    }

    func testRestoresTheSavedSelection() {
        settings.activeProfileName = "Jazz"
        XCTAssertEqual(makeManager().activeProfileName, "Jazz")
    }

    func testFallsBackWhenTheSavedSelectionIsGone() {
        settings.activeProfileName = "A Preset That Was Deleted"
        XCTAssertEqual(makeManager().activeProfileName, BuiltInProfiles.defaultProfileName)
    }

    /// The chain is always eleven ladder filters followed by the free ones, so
    /// the slider strip can index straight into it no matter what was stored.
    func testChainIsNormalisedOnLaunch() {
        let manager = makeManager()
        XCTAssertEqual(manager.bandFilters.count, BuiltInProfiles.bandCount)
        XCTAssertEqual(manager.bandFilters.map(\.band), Array(0..<BuiltInProfiles.bandCount))
        XCTAssertTrue(manager.freeFilters.isEmpty)
    }

    func testRestoresTheWorkingChain() {
        settings.activeProfileName = "Flat"
        var chain = BuiltInProfiles.emptyBandChain()
        for slot in chain.indices { chain[slot].gain = 3 }
        chain.append(EQFilter(kind: .lowShelf, frequency: 180, gain: -4, q: 0.8))
        settings.workingFilters = chain

        let manager = makeManager()
        XCTAssertTrue(manager.bandFilters.allSatisfy { $0.gain == 3 })
        XCTAssertEqual(manager.freeFilters.count, 1)
        XCTAssertEqual(manager.freeFilters[0].kind, .lowShelf)
        XCTAssertTrue(manager.isModified)
    }

    /// Slider tweaks saved by CoreEQ 1.x are carried over once, so an update
    /// doesn't silently discard what the user was listening to.
    func testMigratesLegacyCustomGains() {
        settings.activeProfileName = "Flat"
        settings.legacyCustomGains = Array(repeating: 3.0, count: BuiltInProfiles.bandCount)

        let manager = makeManager()
        XCTAssertTrue(manager.bandFilters.allSatisfy { $0.gain == 3.0 })
        XCTAssertTrue(manager.isModified)
        XCTAssertNil(settings.legacyCustomGains, "the legacy key is consumed, not left to fight the new one")
        XCTAssertNotNil(settings.workingFilters)
    }

    func testIgnoresLegacyCustomGainsOfTheWrongLength() {
        settings.activeProfileName = "Flat"
        settings.legacyCustomGains = [1, 2, 3]

        XCTAssertFalse(makeManager().isModified)
    }

    /// A preset saved under an older band ladder must adopt the current one,
    /// or its sliders would be labelled differently from every other preset.
    func testStoredProfilesAreAlignedToTheCurrentLadder() {
        var stale = EQProfile(
            name: "Stale",
            filters: (0..<BuiltInProfiles.bandCount).map { EQFilter.band(slot: $0, gain: 1) }
        )
        stale.filters[stale.filters.count - 2].frequency = 15_000   // the old value
        settings.userProfiles = [stale]

        let restored = makeManager().userProfiles[0]
        XCTAssertEqual(restored.bandFilters.map(\.frequency), BuiltInProfiles.frequencies)
        XCTAssertTrue(restored.bandFilters.allSatisfy { $0.gain == 1 }, "alignment must preserve gains")
    }

    func testStoredProfileWithMissingBandsIsFilledOutToTheLadder() {
        settings.userProfiles = [EQProfile(name: "Short", filters: [EQFilter.band(slot: 0, gain: 2)])]

        let restored = makeManager().userProfiles[0]
        XCTAssertEqual(restored.filters.count, BuiltInProfiles.bandCount)
        XCTAssertEqual(restored.bandFilters[0].gain, 2)
        XCTAssertTrue(restored.bandFilters.dropFirst().allSatisfy { $0.gain == 0 })
    }

    func testStoredFreeFiltersArePreservedAndCapped() {
        let free = (0..<(BuiltInProfiles.maxFreeFilters + 5)).map {
            EQFilter(frequency: Double(100 + $0 * 10), gain: 1, q: 1)
        }
        settings.userProfiles = [EQProfile(name: "Many", filters: BuiltInProfiles.emptyBandChain() + free)]

        let restored = makeManager().userProfiles[0]
        XCTAssertEqual(restored.freeFilters.count, BuiltInProfiles.maxFreeFilters)
    }

    func testStoredProfileCollidingWithABuiltInIsDropped() {
        settings.userProfiles = [EQProfile(name: "Jazz", filters: BuiltInProfiles.all[0].filters)]
        XCTAssertTrue(makeManager().userProfiles.isEmpty)
    }

    // MARK: - Creating and naming

    func testAddedProfileBecomesActiveAndAwaitsRename() {
        let manager = makeManager()
        let name = manager.addProfile()

        XCTAssertEqual(manager.activeProfileName, name)
        XCTAssertEqual(manager.profileAwaitingRename, name)
        XCTAssertTrue(manager.canEditProfile(named: name))
    }

    func testNamesAreMadeUnique() {
        let manager = makeManager()
        XCTAssertEqual(manager.addProfile(named: "Mine"), "Mine")
        XCTAssertEqual(manager.addProfile(named: "Mine"), "Mine 2")
        XCTAssertEqual(manager.addProfile(named: "Mine"), "Mine 3")
    }

    func testNewNameCannotCollideWithABuiltIn() {
        XCTAssertEqual(makeManager().addProfile(named: "Rock"), "Rock 2")
    }

    func testDuplicateCopiesTheChainOfABuiltIn() {
        let manager = makeManager()
        let copy = manager.duplicateProfile(named: "Jazz")

        XCTAssertEqual(copy, "Jazz copy")
        XCTAssertEqual(manager.profile(named: "Jazz copy")?.filters, manager.profile(named: "Jazz")?.filters)
    }

    func testRenameKeepsTheProfileActive() {
        let manager = makeManager()
        let original = manager.addProfile(named: "Before")

        XCTAssertEqual(manager.renameProfile(named: original, to: "After"), "After")
        XCTAssertEqual(manager.activeProfileName, "After")
    }

    func testRenameRejectsEmptyNames() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Keep")

        XCTAssertNil(manager.renameProfile(named: name, to: "   "))
        XCTAssertEqual(manager.activeProfileName, "Keep")
    }

    func testRenameToATakenNameGetsASuffix() {
        let manager = makeManager()
        manager.addProfile(named: "Taken")
        let other = manager.addProfile(named: "Other")

        XCTAssertEqual(manager.renameProfile(named: other, to: "Taken"), "Taken 2")
    }

    func testBuiltInsCannotBeRenamedOrEdited() {
        let manager = makeManager()
        XCTAssertFalse(manager.canEditProfile(named: "Rock"))
        XCTAssertNil(manager.renameProfile(named: "Rock", to: "My Rock"))

        manager.beginRename(of: "Rock")
        XCTAssertNil(manager.profileAwaitingRename)
    }

    // MARK: - Deleting

    func testDeletingTheActiveProfileFallsBackToItsNeighbour() {
        let manager = makeManager()
        manager.addProfile(named: "First")
        let second = manager.addProfile(named: "Second")
        manager.addProfile(named: "Third")

        manager.setActiveProfile(name: second)
        manager.deleteProfile(named: second)

        XCTAssertEqual(manager.activeProfileName, "Third")
    }

    func testDeletingTheLastUserProfileFallsBackToTheDefault() {
        let manager = makeManager()
        let only = manager.addProfile(named: "Only")
        manager.deleteProfile(named: only)

        XCTAssertEqual(manager.activeProfileName, BuiltInProfiles.defaultProfileName)
        XCTAssertTrue(manager.userProfiles.isEmpty)
    }

    func testDeletingAnInactiveProfileLeavesTheSelectionAlone() {
        let manager = makeManager()
        let spare = manager.addProfile(named: "Spare")
        manager.setActiveProfile(name: "Jazz")

        manager.deleteProfile(named: spare)
        XCTAssertEqual(manager.activeProfileName, "Jazz")
    }

    func testDeletingClearsAPendingRename() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Doomed")
        XCTAssertNotNil(manager.profileAwaitingRename)

        manager.deleteProfile(named: name)
        XCTAssertNil(manager.profileAwaitingRename)
    }

    // MARK: - Band editing

    func testSetGainClampsToTheSliderRange() {
        let manager = makeManager()
        manager.setGain(99, forBandAt: 0)
        XCTAssertEqual(manager.bandFilters[0].gain, BuiltInProfiles.gainRange.upperBound)

        manager.setGain(-99, forBandAt: 0)
        XCTAssertEqual(manager.bandFilters[0].gain, BuiltInProfiles.gainRange.lowerBound)
    }

    func testSetGainOutOfBoundsIsIgnored() {
        let manager = makeManager()
        let before = manager.currentFilters
        manager.setGain(3, forBandAt: 999)
        XCTAssertEqual(manager.currentFilters, before)
    }

    /// A slider must never reach a free filter, or the number over the knob
    /// would stop describing what the knob does.
    func testSetGainCannotReachAFreeFilter() {
        let manager = makeManager()
        manager.addFilter(frequency: 180, gain: 5)
        manager.setGain(9, forBandAt: BuiltInProfiles.bandCount)

        XCTAssertEqual(manager.freeFilters[0].gain, 5)
    }

    func testResetBandRestoresTheProfileValue() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Jazz")
        let original = manager.bandFilters[2].gain

        manager.setGain(original + 5, forBandAt: 2)
        XCTAssertTrue(manager.isModified)

        manager.resetBand(at: 2)
        XCTAssertEqual(manager.bandFilters[2].gain, original)
        XCTAssertFalse(manager.isModified)
    }

    func testResetToActiveProfileClearsEveryTweak() {
        let manager = makeManager()
        manager.setGain(7, forBandAt: 0)
        manager.addFilter(frequency: 180, gain: 3)

        manager.resetToActiveProfile()
        XCTAssertFalse(manager.isModified)
        XCTAssertTrue(manager.freeFilters.isEmpty)
        XCTAssertNil(settings.workingFilters)
    }

    // MARK: - Free filters

    func testAddingAFilterLeavesTheLadderAlone() {
        let manager = makeManager()
        let ladder = manager.bandFilters

        manager.addFilter(kind: .bell, frequency: 180, gain: 3, q: 0.8)

        XCTAssertEqual(manager.bandFilters, ladder, "no slider may move when a filter is added")
        XCTAssertEqual(manager.freeFilters.count, 1)
        XCTAssertTrue(manager.isModified)
    }

    func testAddedFilterDefaultsToSilence() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.addFilter()

        // 0 dB is identity, so placing a filter is not yet an edit to the sound.
        XCTAssertEqual(total(manager.currentFilters, at: 1_000), 0, accuracy: 1e-9)
    }

    func testFilterCountIsCapped() {
        let manager = makeManager()
        for _ in 0..<BuiltInProfiles.maxFreeFilters {
            XCTAssertNotNil(manager.addFilter())
        }
        XCTAssertFalse(manager.canAddFilter)
        XCTAssertNil(manager.addFilter(), "the render budget is a real limit")
        XCTAssertEqual(manager.freeFilters.count, BuiltInProfiles.maxFreeFilters)
    }

    func testFilterParametersAreClamped() {
        let manager = makeManager()
        guard let id = manager.addFilter() else { return XCTFail("filter not added") }

        manager.setFilterFrequency(99_999, id: id)
        XCTAssertEqual(manager.freeFilters[0].frequency, BuiltInProfiles.filterFrequencyRange.upperBound)

        manager.setFilterQ(0, id: id)
        XCTAssertEqual(manager.freeFilters[0].q, BuiltInProfiles.filterQRange.lowerBound)

        manager.setFilterGain(99, id: id)
        XCTAssertEqual(manager.freeFilters[0].gain, BuiltInProfiles.gainRange.upperBound)
    }

    func testRemovingAFilterLeavesTheLadderIntact() {
        let manager = makeManager()
        guard let id = manager.addFilter(frequency: 180, gain: 4) else { return XCTFail("filter not added") }

        manager.removeFilter(id: id)
        XCTAssertTrue(manager.freeFilters.isEmpty)
        XCTAssertEqual(manager.bandFilters.count, BuiltInProfiles.bandCount)
        XCTAssertFalse(manager.isModified)
    }

    func testDisablingAFilterRemovesItFromTheResponse() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        guard let id = manager.addFilter(frequency: 1_000, gain: 6) else { return XCTFail("filter not added") }
        XCTAssertEqual(total(manager.currentFilters, at: 1_000), 6, accuracy: 0.01)

        manager.setFilterEnabled(false, id: id)
        XCTAssertEqual(total(manager.currentFilters, at: 1_000), 0, accuracy: 1e-9)
    }

    func testSectionTogglesSwitchEachHalfOfTheChain() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(6, forBandAt: 5)                   // 1 kHz
        manager.addFilter(frequency: 1_000, gain: 6)

        manager.setBandsEnabled(false)
        XCTAssertEqual(total(manager.currentFilters, at: 1_000), 6, accuracy: 0.01, "only the filter remains")

        manager.setBandsEnabled(true)
        manager.setFreeFiltersEnabled(false)
        XCTAssertEqual(total(manager.currentFilters, at: 1_000), 6, accuracy: 0.01, "only the ladder remains")
    }

    // MARK: - Reading the chain

    /// The number the slider tick shows. It has to include free filters, or the
    /// tick would never differ from the knob and would carry no information.
    func testTotalGainSumsTheWholeChain() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(4, forBandAt: 5)                   // 1 kHz band
        manager.addFilter(frequency: 1_000, gain: 3)       // free filter on top

        XCTAssertEqual(manager.totalGain(at: 1_000, sampleRate: 48_000), 7, accuracy: 0.01)
        XCTAssertEqual(manager.bandFilters[5].gain, 4, "the band still reports only its own gain")
    }

    // MARK: - Global gain

    func testPreampIsClampedAndCountsAsAnEdit() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        XCTAssertFalse(manager.isModified)

        manager.setPreamp(99)
        XCTAssertEqual(manager.currentPreamp, BuiltInProfiles.preampRange.upperBound)
        XCTAssertTrue(manager.isModified, "the trim changes the sound, so it is an unsaved change")

        manager.setPreamp(-99)
        XCTAssertEqual(manager.currentPreamp, BuiltInProfiles.preampRange.lowerBound)
    }

    /// The trim shifts the whole curve, so the number under a slider — and the
    /// tick on its track — has to move with it.
    func testTotalGainIncludesThePreamp() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(4, forBandAt: 5)
        manager.setPreamp(-3)

        XCTAssertEqual(manager.totalGain(at: 1_000, sampleRate: 48_000), 1, accuracy: 0.01)
        XCTAssertEqual(manager.bandFilters[5].gain, 4, "the band still reports only its own gain")
    }

    func testPreampIsSavedIntoAndRestoredFromAPreset() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Trimmed")
        manager.setPreamp(-4.5)
        manager.saveChangesToActiveProfile()
        XCTAssertFalse(manager.isModified)
        XCTAssertEqual(manager.profile(named: name)?.preamp, -4.5)

        manager.setActiveProfile(name: "Rock")
        XCTAssertEqual(manager.currentPreamp, 0, "a preset carries its own trim, and Rock has none")

        manager.setActiveProfile(name: name)
        XCTAssertEqual(manager.currentPreamp, -4.5)
    }

    func testPreampSurvivesRelaunchAndRoundTripsThroughJSON() throws {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.setPreamp(2.5)
        XCTAssertEqual(makeManager().currentPreamp, 2.5)

        let profile = EQProfile(name: "P", filters: BuiltInProfiles.emptyBandChain(), preamp: -6)
        let decoded = try JSONDecoder().decode(EQProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.preamp, -6)
    }

    func testResetToActiveProfileRestoresThePreamp() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        manager.setPreamp(-5)

        manager.resetToActiveProfile()
        XCTAssertEqual(manager.currentPreamp, 0)
        XCTAssertFalse(manager.isModified)
        XCTAssertNil(settings.workingPreamp)
    }

    // MARK: - Edit as filter

    /// A move, not a conversion: the lifted filter keeps every parameter, the
    /// slot stays in the strip at 0 dB, and the chain's response is unchanged.
    func testEditBandAsFilterPreservesTheSound() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        let before = manager.currentFilters
        let probes = [32.0, 125.0, 180.0, 1_000.0, 8_000.0, 16_000.0]
        let responseBefore = probes.map { total(before, at: $0) }

        guard let id = manager.editBandAsFilter(slot: 2) else { return XCTFail("band not lifted") }

        for (probe, expected) in zip(probes, responseBefore) {
            XCTAssertEqual(
                total(manager.currentFilters, at: probe), expected, accuracy: 1e-9,
                "the sound changed at \(probe) Hz"
            )
        }

        XCTAssertEqual(manager.bandFilters.count, BuiltInProfiles.bandCount, "the ladder keeps its eleven sliders")
        XCTAssertEqual(manager.bandFilters[2].gain, 0, "the emptied slot is identity")
        let lifted = manager.freeFilters.first { $0.id == id }
        XCTAssertEqual(lifted?.frequency, BuiltInProfiles.frequencies[2])
        XCTAssertEqual(lifted?.q, BuiltInProfiles.defaultQ)
        XCTAssertEqual(lifted?.band, nil, "a lifted filter no longer belongs to a slot")
    }

    func testEditBandAsFilterRefusesWhenFullRatherThanDroppingTheBand() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        for _ in 0..<BuiltInProfiles.maxFreeFilters { manager.addFilter() }
        let gain = manager.bandFilters[2].gain

        XCTAssertNil(manager.editBandAsFilter(slot: 2))
        XCTAssertEqual(manager.bandFilters[2].gain, gain, "a refused lift must not empty the slot")
    }

    // MARK: - Presets replace the whole chain

    /// A preset is the complete sound, so selecting one clears free filters too.
    /// Otherwise "Flat" would mean flat plus whatever was left over.
    func testSelectingAProfileReplacesTheWholeChain() {
        let manager = makeManager()
        manager.setGain(9, forBandAt: 0)
        manager.addFilter(frequency: 180, gain: 5)

        manager.setActiveProfile(name: "Rock")
        XCTAssertFalse(manager.isModified)
        XCTAssertTrue(manager.freeFilters.isEmpty, "a preset carries its own filters, and Rock has none")
        XCTAssertEqual(manager.currentFilters, manager.profile(named: "Rock")?.filters)
    }

    func testFlatIsFlat() {
        let manager = makeManager()
        manager.addFilter(frequency: 180, gain: 6)
        manager.setActiveProfile(name: "Flat")

        for probe in [32.0, 180.0, 1_000.0, 16_000.0] {
            XCTAssertEqual(total(manager.currentFilters, at: probe), 0, accuracy: 1e-9, "at \(probe) Hz")
        }
    }

    func testSaveChangesWritesTheWholeChainIntoTheProfile() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Mine")
        manager.setGain(6, forBandAt: 3)
        manager.addFilter(kind: .highShelf, frequency: 8_000, gain: -2, q: 0.7)
        XCTAssertTrue(manager.isModified)

        manager.saveChangesToActiveProfile()
        XCTAssertFalse(manager.isModified)
        XCTAssertEqual(manager.profile(named: name)?.bandFilters[3].gain, 6)
        XCTAssertEqual(manager.profile(named: name)?.freeFilters.count, 1)
        XCTAssertEqual(manager.profile(named: name)?.freeFilters.first?.kind, .highShelf)
    }

    func testSaveChangesDoesNothingForABuiltIn() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        manager.setGain(0, forBandAt: 0)

        manager.saveChangesToActiveProfile()
        XCTAssertEqual(
            manager.profile(named: "Rock")?.filters,
            BuiltInProfiles.all.first { $0.name == "Rock" }?.filters
        )
    }

    // MARK: - Quick EQ tone

    func testToneOffsetsAreLayeredOnTheActiveProfile() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setTone(bass: 6)

        XCTAssertGreaterThan(manager.bandFilters[0].gain, 0, "32 Hz should follow the bass control")
        XCTAssertEqual(manager.bandFilters.last?.gain, 0, "20 kHz should not")
    }

    /// The tone controls are a shortcut into the ladder, not into the chain.
    func testToneLeavesFreeFiltersAlone() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.addFilter(frequency: 180, gain: 5)

        manager.setTone(bass: 6)
        XCTAssertEqual(manager.freeFilters.count, 1)
        XCTAssertEqual(manager.freeFilters[0].gain, 5)
    }

    func testToneIsClampedAndPersisted() {
        let manager = makeManager()
        manager.setTone(bass: 999)
        XCTAssertEqual(manager.tone.bass, QuickTone.range.upperBound)
        XCTAssertNotNil(settings.tone)
    }

    func testSelectingAProfileRecentresTone() {
        let manager = makeManager()
        manager.setTone(bass: 5, mid: -2)
        XCTAssertFalse(manager.tone.isNeutral)

        manager.setActiveProfile(name: "Rock")
        XCTAssertTrue(manager.tone.isNeutral)
        XCTAssertNil(settings.tone)
    }

    func testToneSurvivesRelaunch() {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.setTone(treble: 4)
        let expected = first.currentFilters

        XCTAssertEqual(makeManager().currentFilters, expected)
    }

    // MARK: - Persistence

    func testUserProfilesSurviveRelaunch() {
        let first = makeManager()
        first.addProfile(named: "Kept")
        first.setGain(5, forBandAt: 0)
        first.saveChangesToActiveProfile()

        let second = makeManager()
        XCTAssertEqual(second.userProfiles.map(\.name), ["Kept"])
        XCTAssertEqual(second.profile(named: "Kept")?.bandFilters[0].gain, 5)
    }

    func testUnsavedFreeFiltersSurviveRelaunch() {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.addFilter(kind: .highPass, frequency: 40, gain: 0, q: 0.707)
        let expected = first.currentFilters

        let second = makeManager()
        XCTAssertEqual(second.currentFilters, expected)
        XCTAssertEqual(second.freeFilters.first?.kind, .highPass)
        XCTAssertTrue(second.isModified)
    }

    func testAnUnmodifiedChainStoresNothing() {
        let manager = makeManager()
        guard let id = manager.addFilter(frequency: 180, gain: 4) else { return XCTFail("filter not added") }
        XCTAssertNotNil(settings.workingFilters)

        manager.removeFilter(id: id)
        XCTAssertNil(settings.workingFilters, "back to the preset means nothing to remember")
    }

    func testProfilesListsBuiltInsBeforeUserPresets() {
        let manager = makeManager()
        manager.addProfile(named: "Mine")

        XCTAssertEqual(manager.profiles.count, BuiltInProfiles.all.count + 1)
        XCTAssertEqual(manager.profiles.last?.name, "Mine")
        XCTAssertEqual(manager.profiles.first?.name, BuiltInProfiles.all[0].name)
    }
}
