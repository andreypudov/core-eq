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

    private func makeManager(device: String? = nil) -> ProfileManager {
        ProfileManager(settings: settings, outputDeviceUID: device)
    }

    /// What was filed for a device, or for the no-device slot.
    private func storedState(device: String? = nil) -> DeviceEQState? {
        settings.deviceStates[device ?? ""]
    }

    private func seed(_ state: DeviceEQState, device: String? = nil) {
        settings.deviceStates[device ?? ""] = state
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
        seed(DeviceEQState(profileName: "Jazz"))
        XCTAssertEqual(makeManager().activeProfileName, "Jazz")
    }

    func testFallsBackWhenTheSavedSelectionIsGone() {
        seed(DeviceEQState(profileName: "A Preset That Was Deleted"))
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
        var chain = BuiltInProfiles.emptyBandChain()
        for slot in chain.indices { chain[slot].gain = 3 }
        chain.append(EQFilter(kind: .lowShelf, frequency: 180, gain: -4, q: 0.8))
        seed(DeviceEQState(profileName: "Flat", filters: chain))

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
        XCTAssertNotNil(storedState()?.filters, "the migrated chain lands in the device's slot")
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
        XCTAssertNil(storedState()?.filters)
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

    /// Colours are what tell one band's row and one node on the graph from
    /// another's, so bands added one after another must not arrive matching.
    func testAddedFiltersTakeDistinctColours() {
        let manager = makeManager()
        for _ in 0..<EQFilter.colorCount {
            XCTAssertNotNil(manager.addFilter())
        }

        let colors = manager.freeFilters.map(\.colorIndex)
        XCTAssertEqual(Set(colors).count, EQFilter.colorCount, "the palette is used up before any of it repeats")
    }

    /// A colour freed by a removal is the next one handed out, rather than the
    /// palette marching on and leaving gaps.
    func testAFreedColourIsReused() {
        let manager = makeManager()
        guard let first = manager.addFilter(), manager.addFilter() != nil else {
            return XCTFail("filters not added")
        }
        let freed = manager.freeFilters[0].colorIndex

        manager.removeFilter(id: first)
        XCTAssertNotNil(manager.addFilter())
        XCTAssertTrue(manager.freeFilters.contains { $0.colorIndex == freed })
    }

    /// Colour is presentation, but it is presentation the user chose, so it has
    /// to survive the round trip through the device's stored state.
    func testFilterColourSurvivesRelaunch() {
        let manager = makeManager()
        guard let id = manager.addFilter() else { return XCTFail("filter not added") }
        manager.setFilterColor(5, id: id)

        XCTAssertEqual(makeManager().freeFilters.first?.colorIndex, 5)
    }

    /// A band lifted out of the ladder joins bands that already have colours,
    /// so it needs one that isn't taken rather than the ladder's default.
    func testLiftedBandTakesAnUnusedColour() {
        let manager = makeManager()
        manager.addFilter()
        XCTAssertNotNil(manager.editBandAsFilter(slot: 4))

        XCTAssertEqual(Set(manager.freeFilters.map(\.colorIndex)).count, 2)
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

    /// The trim lifts every frequency equally, so it says nothing about any one
    /// band. Folding it into the per-band total would put a tick on all eleven
    /// sliders the moment it left zero.
    func testTotalGainExcludesThePreamp() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(4, forBandAt: 5)
        manager.setPreamp(-3)

        XCTAssertEqual(manager.totalGain(at: 1_000, sampleRate: 48_000), 4, accuracy: 0.01)

        // Three octaves up, only the tail of the 1 kHz bell reaches — a few
        // hundredths of a dB, nowhere near the −3 dB trim. A band nothing
        // overlaps shows no tick however the trim is set.
        XCTAssertEqual(manager.totalGain(at: 8_000, sampleRate: 48_000), 0, accuracy: 0.05)
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
        XCTAssertEqual(storedState()?.preamp, 0)
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
        XCTAssertNotNil(storedState()?.tone)
    }

    func testSelectingAProfileRecentresTone() {
        let manager = makeManager()
        manager.setTone(bass: 5, mid: -2)
        XCTAssertFalse(manager.tone.isNeutral)

        manager.setActiveProfile(name: "Rock")
        XCTAssertTrue(manager.tone.isNeutral)
        XCTAssertNil(storedState()?.tone)
    }

    func testToneSurvivesRelaunch() {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.setTone(treble: 4)
        let expected = first.currentFilters

        XCTAssertEqual(makeManager().currentFilters, expected)
    }

    // MARK: - Per-device state

    /// The point of the feature: what you set for headphones stays with the
    /// headphones, and the speakers keep their own.
    func testEachDeviceKeepsItsOwnSound() {
        let manager = makeManager(device: "headphones")
        manager.setActiveProfile(name: "Rock")
        manager.setGain(6, forBandAt: 0)
        manager.setPreamp(-3)

        manager.setOutputDevice(uid: "speakers")
        XCTAssertEqual(manager.activeProfileName, BuiltInProfiles.defaultProfileName,
                       "a device never seen before starts at the default, not at whatever was playing")
        XCTAssertEqual(manager.currentPreamp, 0)
        XCTAssertFalse(manager.isModified)

        manager.setActiveProfile(name: "Jazz")

        manager.setOutputDevice(uid: "headphones")
        XCTAssertEqual(manager.activeProfileName, "Rock")
        XCTAssertEqual(manager.bandFilters[0].gain, 6)
        XCTAssertEqual(manager.currentPreamp, -3)

        manager.setOutputDevice(uid: "speakers")
        XCTAssertEqual(manager.activeProfileName, "Jazz")
    }

    func testDeviceStateSurvivesRelaunch() {
        let first = makeManager(device: "headphones")
        first.setActiveProfile(name: "Rock")
        first.setPreamp(-2.5)
        first.setTone(bass: 4)

        let second = makeManager(device: "headphones")
        XCTAssertEqual(second.activeProfileName, "Rock")
        XCTAssertEqual(second.currentPreamp, -2.5)
        XCTAssertEqual(second.tone.bass, 4)

        XCTAssertEqual(makeManager(device: "speakers").activeProfileName,
                       BuiltInProfiles.defaultProfileName)
    }

    func testSwitchingToTheSameDeviceChangesNothing() {
        let manager = makeManager(device: "headphones")
        manager.setGain(5, forBandAt: 2)
        let before = manager.currentFilters

        manager.setOutputDevice(uid: "headphones")
        XCTAssertEqual(manager.currentFilters, before, "a redundant switch must not reload and discard edits")
    }

    /// Presets are a shared library; only the selection follows the hardware.
    func testPresetsAreSharedAcrossDevices() {
        let manager = makeManager(device: "headphones")
        let name = manager.addProfile(named: "Mine")

        manager.setOutputDevice(uid: "speakers")
        XCTAssertNotNil(manager.profile(named: name))
        manager.setActiveProfile(name: name)
        XCTAssertEqual(manager.activeProfileName, name)
    }

    /// A rename has to follow every device that had that preset selected, or
    /// the others silently fall back to Flat the next time they are used.
    func testRenamingAPresetFollowsEveryDeviceUsingIt() {
        let manager = makeManager(device: "headphones")
        let name = manager.addProfile(named: "Mine")
        manager.setOutputDevice(uid: "speakers")
        manager.setActiveProfile(name: name)
        manager.setOutputDevice(uid: "headphones")

        XCTAssertEqual(manager.renameProfile(named: name, to: "Renamed"), "Renamed")

        manager.setOutputDevice(uid: "speakers")
        XCTAssertEqual(manager.activeProfileName, "Renamed")
    }

    /// State written before the per-device model lands in the current device's
    /// slot, so an update doesn't read as having lost the user's EQ.
    func testLegacyStateMigratesIntoTheCurrentDevice() {
        settings.activeProfileName = "Rock"
        settings.workingPreamp = -4

        let manager = makeManager(device: "headphones")
        XCTAssertEqual(manager.activeProfileName, "Rock")
        XCTAssertEqual(manager.currentPreamp, -4)
        XCTAssertNil(settings.activeProfileName, "the legacy keys are consumed once")
        XCTAssertEqual(storedState(device: "headphones")?.profileName, "Rock")
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
        XCTAssertNotNil(storedState()?.filters)

        manager.removeFilter(id: id)
        XCTAssertNil(storedState()?.filters, "back to the preset means nothing to remember")
    }

    func testProfilesListsBuiltInsBeforeUserPresets() {
        let manager = makeManager()
        manager.addProfile(named: "Mine")

        XCTAssertEqual(manager.profiles.count, BuiltInProfiles.all.count + 1)
        XCTAssertEqual(manager.profiles.last?.name, "Mine")
        XCTAssertEqual(manager.profiles.first?.name, BuiltInProfiles.all[0].name)
    }
}
