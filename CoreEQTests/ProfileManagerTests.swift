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

    func testRestoresCustomGains() {
        settings.activeProfileName = "Flat"
        settings.customGains = Array(repeating: 3.0, count: BuiltInProfiles.frequencies.count)

        let manager = makeManager()
        XCTAssertTrue(manager.currentBands.allSatisfy { $0.gain == 3.0 })
        XCTAssertTrue(manager.isModified)
    }

    func testIgnoresCustomGainsOfTheWrongLength() {
        settings.activeProfileName = "Flat"
        settings.customGains = [1, 2, 3]

        XCTAssertFalse(makeManager().isModified)
    }

    /// A preset saved under an older band ladder must adopt the current one,
    /// or its sliders would be labelled differently from every other preset.
    func testStoredProfilesAreAlignedToTheCurrentLadder() {
        var stale = EQProfile(
            name: "Stale",
            bands: BuiltInProfiles.frequencies.map { EQBand(frequency: $0, gain: 1) }
        )
        stale.bands[stale.bands.count - 2].frequency = 15_000   // the old value
        settings.userProfiles = [stale]

        let restored = makeManager().userProfiles[0]
        XCTAssertEqual(restored.bands.map(\.frequency), BuiltInProfiles.frequencies)
        XCTAssertTrue(restored.bands.allSatisfy { $0.gain == 1 }, "alignment must preserve gains")
    }

    func testStoredProfileWithADifferentBandCountIsLeftAlone() {
        let odd = EQProfile(name: "Odd", bands: [EQBand(frequency: 100, gain: 2)])
        settings.userProfiles = [odd]

        XCTAssertEqual(makeManager().userProfiles[0].bands.count, 1)
    }

    func testStoredProfileCollidingWithABuiltInIsDropped() {
        settings.userProfiles = [EQProfile(name: "Jazz", bands: BuiltInProfiles.all[0].bands)]
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

    func testDuplicateCopiesTheBandsOfABuiltIn() {
        let manager = makeManager()
        let copy = manager.duplicateProfile(named: "Jazz")

        XCTAssertEqual(copy, "Jazz copy")
        XCTAssertEqual(manager.profile(named: "Jazz copy")?.bands, manager.profile(named: "Jazz")?.bands)
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
        XCTAssertEqual(manager.currentBands[0].gain, BuiltInProfiles.gainRange.upperBound)

        manager.setGain(-99, forBandAt: 0)
        XCTAssertEqual(manager.currentBands[0].gain, BuiltInProfiles.gainRange.lowerBound)
    }

    func testSetGainOutOfBoundsIsIgnored() {
        let manager = makeManager()
        let before = manager.currentBands
        manager.setGain(3, forBandAt: 999)
        XCTAssertEqual(manager.currentBands, before)
    }

    func testResetBandRestoresTheProfileValue() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Jazz")
        let original = manager.currentBands[2].gain

        manager.setGain(original + 5, forBandAt: 2)
        XCTAssertTrue(manager.isModified)

        manager.resetBand(at: 2)
        XCTAssertEqual(manager.currentBands[2].gain, original)
        XCTAssertFalse(manager.isModified)
    }

    func testResetToActiveProfileClearsEveryTweak() {
        let manager = makeManager()
        manager.setGain(7, forBandAt: 0)
        manager.setGain(-7, forBandAt: 1)

        manager.resetToActiveProfile()
        XCTAssertFalse(manager.isModified)
        XCTAssertNil(settings.customGains)
    }

    func testSwitchingProfileDiscardsTweaks() {
        let manager = makeManager()
        manager.setGain(9, forBandAt: 0)

        manager.setActiveProfile(name: "Rock")
        XCTAssertFalse(manager.isModified)
        XCTAssertEqual(manager.currentBands, manager.profile(named: "Rock")?.bands)
    }

    func testSaveChangesWritesTheWorkingValuesIntoTheProfile() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Mine")
        manager.setGain(6, forBandAt: 3)
        XCTAssertTrue(manager.isModified)

        manager.saveChangesToActiveProfile()
        XCTAssertFalse(manager.isModified)
        XCTAssertEqual(manager.profile(named: name)?.bands[3].gain, 6)
    }

    func testSaveChangesDoesNothingForABuiltIn() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        manager.setGain(0, forBandAt: 0)

        manager.saveChangesToActiveProfile()
        XCTAssertEqual(manager.profile(named: "Rock")?.bands, BuiltInProfiles.all.first { $0.name == "Rock" }?.bands)
    }

    // MARK: - Quick EQ tone

    func testToneOffsetsAreLayeredOnTheActiveProfile() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setTone(bass: 6)

        XCTAssertGreaterThan(manager.currentBands[0].gain, 0, "32 Hz should follow the bass control")
        XCTAssertEqual(manager.currentBands.last?.gain, 0, "20 kHz should not")
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
        let expected = first.currentBands

        XCTAssertEqual(makeManager().currentBands, expected)
    }

    // MARK: - Persistence

    func testUserProfilesSurviveRelaunch() {
        let first = makeManager()
        first.addProfile(named: "Kept")
        first.setGain(5, forBandAt: 0)
        first.saveChangesToActiveProfile()

        let second = makeManager()
        XCTAssertEqual(second.userProfiles.map(\.name), ["Kept"])
        XCTAssertEqual(second.profile(named: "Kept")?.bands[0].gain, 5)
    }

    func testProfilesListsBuiltInsBeforeUserPresets() {
        let manager = makeManager()
        manager.addProfile(named: "Mine")

        XCTAssertEqual(manager.profiles.count, BuiltInProfiles.all.count + 1)
        XCTAssertEqual(manager.profiles.last?.name, "Mine")
        XCTAssertEqual(manager.profiles.first?.name, BuiltInProfiles.all[0].name)
    }
}
