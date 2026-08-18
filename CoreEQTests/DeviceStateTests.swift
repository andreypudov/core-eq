import XCTest

/// What CoreEQ remembers: per output device, across a relaunch, and between the
/// two working states a device holds.
@MainActor
final class DeviceStateTests: XCTestCase {
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

    /// Total response of a chain at `frequency`, the way the graph computes the
    /// curve it draws.
    private func total(
        _ filters: [EQFilter], at frequency: Double, sampleRate: Double = 48_000
    ) -> Double {
        filters.reduce(0.0) {
            $0
                + Biquad(filter: $1, sampleRate: sampleRate).magnitudeDB(
                    at: frequency, sampleRate: sampleRate)
        }
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
        XCTAssertEqual(
            manager.activeProfileName, BuiltInProfiles.defaultProfileName,
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

        XCTAssertEqual(
            makeManager(device: "speakers").activeProfileName,
            BuiltInProfiles.defaultProfileName)
    }

    func testSwitchingToTheSameDeviceChangesNothing() {
        let manager = makeManager(device: "headphones")
        manager.setGain(5, forBandAt: 2)
        let before = manager.currentFilters

        manager.setOutputDevice(uid: "headphones")
        XCTAssertEqual(
            manager.currentFilters, before, "a redundant switch must not reload and discard edits")
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

    /// Launching on a device and switching to it have to read its stored slot
    /// the same way.
    ///
    /// They were separate pieces of code, and had drifted: a slot holding an
    /// explicit centred tone alongside an edited chain restored the edits on
    /// launch and threw them away on a switch. Nothing writes a centred tone
    /// today — it is stored as nil — so this only ever bit a slot written by an
    /// older build, silently, by making a device sound different depending on
    /// how it was arrived at.
    func testASlotReadsTheSameOnLaunchAsOnASwitch() {
        var chain = BuiltInProfiles.emptyBandChain()
        chain[3].gain = 7
        seed(
            DeviceEQState(profileName: "Flat", filters: chain, preamp: -2, tone: [0, 0, 0]),
            device: "headphones"
        )

        let onLaunch = makeManager(device: "headphones")

        let onSwitch = makeManager(device: "speakers")
        onSwitch.setOutputDevice(uid: "headphones")

        XCTAssertEqual(onSwitch.currentFilters, onLaunch.currentFilters)
        XCTAssertEqual(onSwitch.currentPreamp, onLaunch.currentPreamp)
        XCTAssertEqual(onLaunch.currentFilters[3].gain, 7, "the edited chain is what was stored")
    }

    // MARK: - A/B

    /// The first reach for the other slot must change nothing. A comparison that
    /// begins by altering the sound has already lost the thing it compares.
    func testSwitchingToAnUnusedSlotIsSilent() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Jazz")
        manager.setGain(6, forBandAt: 2)
        let before = manager.currentFilters

        manager.setSlot(.b)

        XCTAssertEqual(manager.abSlot, .b)
        XCTAssertEqual(manager.currentFilters, before, "reaching for B changed what was playing")
        XCTAssertEqual(manager.activeProfileName, "Jazz")
    }

    func testEachSlotKeepsItsOwnSound() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(6, forBandAt: 2)
        let a = manager.currentFilters

        manager.setSlot(.b)
        manager.setGain(-6, forBandAt: 2)
        let b = manager.currentFilters
        XCTAssertNotEqual(a, b)

        manager.setSlot(.a)
        XCTAssertEqual(manager.currentFilters, a, "A did not come back as it was left")

        manager.setSlot(.b)
        XCTAssertEqual(manager.currentFilters, b, "B did not come back as it was left")
    }

    /// A slot holds a whole sound, not just a chain: preset, trim and tone go
    /// with it.
    func testASlotCarriesThePresetAndTheTrim() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        manager.setPreamp(-4)

        manager.setSlot(.b)
        manager.setActiveProfile(name: "Jazz")
        manager.setPreamp(2)

        manager.setSlot(.a)
        XCTAssertEqual(manager.activeProfileName, "Rock")
        XCTAssertEqual(manager.currentPreamp, -4)

        manager.setSlot(.b)
        XCTAssertEqual(manager.activeProfileName, "Jazz")
        XCTAssertEqual(manager.currentPreamp, 2)
    }

    func testTheComparisonSurvivesRelaunch() {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.setGain(5, forBandAt: 0)
        first.setSlot(.b)
        first.setGain(-5, forBandAt: 0)

        let second = makeManager()
        XCTAssertEqual(second.abSlot, .b)
        XCTAssertEqual(second.bandFilters[0].gain, -5)

        second.setSlot(.a)
        XCTAssertEqual(second.bandFilters[0].gain, 5, "the other slot did not survive the relaunch")
    }

    /// Each device has its own pair: a comparison set up on headphones is still
    /// there when headphones come back.
    func testTheComparisonBelongsToTheDevice() {
        let manager = makeManager(device: "speakers")
        manager.setActiveProfile(name: "Flat")
        manager.setSlot(.b)
        manager.setGain(7, forBandAt: 3)

        manager.setOutputDevice(uid: "headphones")
        XCTAssertEqual(manager.abSlot, .a, "a device never seen before starts on A")

        manager.setOutputDevice(uid: "speakers")
        XCTAssertEqual(manager.abSlot, .b)
        XCTAssertEqual(manager.bandFilters[3].gain, 7)
    }

    /// Renaming has to follow the preset into the slot nobody is listening to,
    /// or that slot silently falls back to Flat the next time it comes round.
    func testRenamingFollowsThePresetIntoTheOtherSlot() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Mine")
        manager.setSlot(.b)
        manager.setActiveProfile(name: "Rock")

        XCTAssertEqual(manager.renameProfile(named: name, to: "Renamed"), "Renamed")

        manager.setSlot(.a)
        XCTAssertEqual(manager.activeProfileName, "Renamed")
    }

    func testSwitchingToTheSlotAlreadyLiveDoesNothing() {
        let manager = makeManager()
        manager.setGain(3, forBandAt: 1)
        let before = manager.currentFilters

        manager.setSlot(.a)
        XCTAssertEqual(manager.abSlot, .a)
        XCTAssertEqual(manager.currentFilters, before)
    }

    // MARK: - Automatic gain

    func testTurningAutoOnTakesTheTrimOverImmediately() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        for slot in 0..<BuiltInProfiles.bandCount { manager.setGain(6, forBandAt: slot) }
        XCTAssertEqual(manager.currentPreamp, 0, "nothing should have touched the trim yet")

        manager.setAutoGain(true)
        XCTAssertTrue(manager.isAutoGain)
        XCTAssertLessThan(
            manager.currentPreamp, -3, "auto did not pull the trim down for a lifted chain")
    }

    /// The trim has to follow the chain, or it is only right at the moment it is
    /// switched on.
    func testTheComputedTrimFollowsEveryKindOfEdit() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setAutoGain(true)
        XCTAssertEqual(manager.currentPreamp, 0, accuracy: 0.01)

        manager.setGain(9, forBandAt: 5)
        let afterBand = manager.currentPreamp
        XCTAssertLessThan(afterBand, -0.5)

        manager.addFilter(kind: .highShelf, frequency: 8_000, gain: 8, q: 0.7)
        XCTAssertLessThan(
            manager.currentPreamp, afterBand, "adding a boost did not deepen the trim")

        manager.setTone(bass: 6)
        XCTAssertLessThan(manager.currentPreamp, afterBand)
    }

    /// Switching off has to be silent: the number stays where the computation
    /// left it, and only then becomes the user's again.
    func testTurningAutoOffKeepsTheValueAndReturnsTheControl() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(8, forBandAt: 4)
        manager.setAutoGain(true)
        let computed = manager.currentPreamp

        manager.setAutoGain(false)
        XCTAssertFalse(manager.isAutoGain)
        XCTAssertEqual(
            manager.currentPreamp, computed, "the trim jumped when auto was switched off")

        manager.setPreamp(-2)
        XCTAssertEqual(
            manager.currentPreamp, -2, "the slider did not come back under the user's control")
    }

    /// While auto is on the slider is disabled, so a write can only arrive from
    /// a caller that has not looked — and it must not be honoured.
    func testTheTrimCannotBeSetByHandWhileAutoIsOn() {
        let manager = makeManager()
        manager.setGain(6, forBandAt: 0)
        manager.setAutoGain(true)
        let computed = manager.currentPreamp

        manager.setPreamp(11)
        XCTAssertEqual(manager.currentPreamp, computed)
    }

    /// The mode belongs to the sound, so it saves into the preset and comes back
    /// with it.
    func testAutoIsSavedIntoThePresetAndRestoredWithIt() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(7, forBandAt: 2)
        manager.setAutoGain(true)
        let name = manager.addProfile(named: "Auto Preset")
        manager.saveChangesToActiveProfile()

        XCTAssertEqual(manager.profile(named: name)?.autoGain, true)

        manager.setActiveProfile(name: "Rock")
        XCTAssertFalse(manager.isAutoGain, "a preset without auto did not turn it off")

        manager.setActiveProfile(name: name)
        XCTAssertTrue(manager.isAutoGain, "the preset did not bring its mode back")
    }

    func testAutoSurvivesRelaunchAndIsRecomputed() {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.setGain(9, forBandAt: 6)
        first.setAutoGain(true)
        let computed = first.currentPreamp

        let second = makeManager()
        XCTAssertTrue(second.isAutoGain)
        XCTAssertEqual(second.currentPreamp, computed, accuracy: 0.01)
    }

    /// Turning the mode on changes the sound, so the header has to report the
    /// preset as edited.
    func testTurningAutoOnCountsAsAnEdit() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        XCTAssertFalse(manager.isModified)

        manager.setAutoGain(true)
        XCTAssertTrue(manager.isModified)
    }

    /// Each slot carries its own mode, so A can be computed while B is held.
    func testEachSlotCarriesItsOwnAutoSetting() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(8, forBandAt: 3)
        manager.setAutoGain(true)

        manager.setSlot(.b)
        manager.setAutoGain(false)
        manager.setPreamp(4)

        manager.setSlot(.a)
        XCTAssertTrue(manager.isAutoGain)
        XCTAssertLessThan(manager.currentPreamp, 0)

        manager.setSlot(.b)
        XCTAssertFalse(manager.isAutoGain)
        XCTAssertEqual(manager.currentPreamp, 4)
    }

    // MARK: - Persistence

    func testUserProfilesSurviveRelaunch() {
        let first = makeManager()
        first.addProfile(named: "Kept")
        first.setGain(5, forBandAt: 0)
        first.saveChangesToActiveProfile()

        let second = makeManager()
        XCTAssertEqual(second.library.user.map(\.name), ["Kept"])
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
        guard let id = manager.addFilter(frequency: 180, gain: 4) else {
            return XCTFail("filter not added")
        }
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
