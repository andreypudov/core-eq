import Foundation
import Testing

/// What CoreEQ remembers: per output device, across a relaunch, and between the
/// two working states a device holds.
@MainActor final class DeviceStateTests {
    private let store: TemporaryDefaults
    private let defaults: UserDefaults
    private let settings: SettingsStore

    // A class rather than a struct: `deinit` is what stands in for
    // `tearDown()`, and only a class has one. It is `isolated` so it can reach
    // the main-actor properties it has to clean up.
    init() throws {
        store = try #require(TemporaryDefaults())
        defaults = store.values
        settings = SettingsStore(defaults: defaults)
    }

    isolated deinit {
        store.remove()
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
    @Test func eachDeviceKeepsItsOwnSound() {
        let manager = makeManager(device: "headphones")
        manager.setActiveProfile(name: "Rock")
        manager.setGain(6, forBandAt: 0)
        manager.setAutoGain(false)
        manager.setPreamp(-3)

        manager.setOutputDevice(uid: "speakers")
        #expect(
            manager.activeProfileName == BuiltInProfiles.defaultProfileName,
            "a device never seen before starts at the default, not at whatever was playing")
        #expect(manager.currentPreamp == 0)
        #expect(!manager.isModified)

        manager.setActiveProfile(name: "Jazz")

        manager.setOutputDevice(uid: "headphones")
        #expect(manager.activeProfileName == "Rock")
        #expect(manager.bandFilters[0].gain == 6)
        #expect(manager.currentPreamp == -3)

        manager.setOutputDevice(uid: "speakers")
        #expect(manager.activeProfileName == "Jazz")
    }

    @Test func deviceStateSurvivesRelaunch() {
        let first = makeManager(device: "headphones")
        first.setActiveProfile(name: "Rock")
        first.setAutoGain(false)
        first.setPreamp(-2.5)
        first.setTone(bass: 4)

        let second = makeManager(device: "headphones")
        #expect(second.activeProfileName == "Rock")
        #expect(second.currentPreamp == -2.5)
        #expect(second.tone.bass == 4)

        #expect(
            makeManager(device: "speakers").activeProfileName == BuiltInProfiles.defaultProfileName)
    }

    @Test func switchingToTheSameDeviceChangesNothing() {
        let manager = makeManager(device: "headphones")
        manager.setGain(5, forBandAt: 2)
        let before = manager.currentFilters

        manager.setOutputDevice(uid: "headphones")
        #expect(
            manager.currentFilters == before, "a redundant switch must not reload and discard edits"
        )
    }

    /// Presets are a shared library; only the selection follows the hardware.
    @Test func presetsAreSharedAcrossDevices() {
        let manager = makeManager(device: "headphones")
        let name = manager.addProfile(named: "Mine")

        manager.setOutputDevice(uid: "speakers")
        #expect(manager.profile(named: name) != nil)
        manager.setActiveProfile(name: name)
        #expect(manager.activeProfileName == name)
    }

    /// A rename has to follow every device that had that preset selected, or
    /// the others silently fall back to Flat the next time they are used.
    @Test func renamingAPresetFollowsEveryDeviceUsingIt() {
        let manager = makeManager(device: "headphones")
        let name = manager.addProfile(named: "Mine")
        manager.setOutputDevice(uid: "speakers")
        manager.setActiveProfile(name: name)
        manager.setOutputDevice(uid: "headphones")

        #expect(manager.renameProfile(named: name, to: "Renamed") == "Renamed")

        manager.setOutputDevice(uid: "speakers")
        #expect(manager.activeProfileName == "Renamed")
    }

    /// State written before the per-device model lands in the current device's
    /// slot, so an update doesn't read as having lost the user's EQ.
    @Test func legacyStateMigratesIntoTheCurrentDevice() {
        settings.activeProfileName = "Rock"
        settings.workingPreamp = -4

        let manager = makeManager(device: "headphones")
        #expect(manager.activeProfileName == "Rock")
        // The preset comes across; the trim does not. A migrated state adopts
        // the computed mode like any other, and the number it lands on is the
        // one the chain asks for rather than the one stored beside it.
        #expect(manager.isAutoGain)
        #expect(manager.currentPreamp == AutoGain.trim(for: manager.currentFilters))
        #expect(settings.activeProfileName == nil, "the legacy keys are consumed once")
        #expect(storedState(device: "headphones")?.profileName == "Rock")
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
    @Test func aSlotReadsTheSameOnLaunchAsOnASwitch() {
        var chain = BuiltInProfiles.emptyBandChain()
        chain[3].gain = 7
        seed(
            DeviceEQState(profileName: "Flat", filters: chain, preamp: -2, tone: [0, 0, 0]),
            device: "headphones"
        )

        let onLaunch = makeManager(device: "headphones")

        let onSwitch = makeManager(device: "speakers")
        onSwitch.setOutputDevice(uid: "headphones")

        #expect(onSwitch.currentFilters == onLaunch.currentFilters)
        #expect(onSwitch.currentPreamp == onLaunch.currentPreamp)
        #expect(onLaunch.currentFilters[3].gain == 7, "the edited chain is what was stored")
    }

    // MARK: - A/B

    /// The first reach for the other slot must change nothing. A comparison that
    /// begins by altering the sound has already lost the thing it compares.
    @Test func switchingToAnUnusedSlotIsSilent() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Jazz")
        manager.setGain(6, forBandAt: 2)
        let before = manager.currentFilters

        manager.setSlot(.b)

        #expect(manager.abSlot == .b)
        #expect(manager.currentFilters == before, "reaching for B changed what was playing")
        #expect(manager.activeProfileName == "Jazz")
    }

    @Test func eachSlotKeepsItsOwnSound() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(6, forBandAt: 2)
        let a = manager.currentFilters

        manager.setSlot(.b)
        manager.setGain(-6, forBandAt: 2)
        let b = manager.currentFilters
        #expect(a != b)

        manager.setSlot(.a)
        #expect(manager.currentFilters == a, "A did not come back as it was left")

        manager.setSlot(.b)
        #expect(manager.currentFilters == b, "B did not come back as it was left")
    }

    /// A slot holds a whole sound, not just a chain: preset, trim and tone go
    /// with it.
    @Test func aSlotCarriesThePresetAndTheTrim() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        manager.setAutoGain(false)
        manager.setPreamp(-4)

        manager.setSlot(.b)
        manager.setActiveProfile(name: "Jazz")
        manager.setAutoGain(false)
        manager.setPreamp(2)

        manager.setSlot(.a)
        #expect(manager.activeProfileName == "Rock")
        #expect(manager.currentPreamp == -4)

        manager.setSlot(.b)
        #expect(manager.activeProfileName == "Jazz")
        #expect(manager.currentPreamp == 2)
    }

    @Test func theComparisonSurvivesRelaunch() {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.setGain(5, forBandAt: 0)
        first.setSlot(.b)
        first.setGain(-5, forBandAt: 0)

        let second = makeManager()
        #expect(second.abSlot == .b)
        #expect(second.bandFilters[0].gain == -5)

        second.setSlot(.a)
        #expect(second.bandFilters[0].gain == 5, "the other slot did not survive the relaunch")
    }

    /// Each device has its own pair: a comparison set up on headphones is still
    /// there when headphones come back.
    @Test func theComparisonBelongsToTheDevice() {
        let manager = makeManager(device: "speakers")
        manager.setActiveProfile(name: "Flat")
        manager.setSlot(.b)
        manager.setGain(7, forBandAt: 3)

        manager.setOutputDevice(uid: "headphones")
        #expect(manager.abSlot == .a, "a device never seen before starts on A")

        manager.setOutputDevice(uid: "speakers")
        #expect(manager.abSlot == .b)
        #expect(manager.bandFilters[3].gain == 7)
    }

    /// Renaming has to follow the preset into the slot nobody is listening to,
    /// or that slot silently falls back to Flat the next time it comes round.
    @Test func renamingFollowsThePresetIntoTheOtherSlot() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Mine")
        manager.setSlot(.b)
        manager.setActiveProfile(name: "Rock")

        #expect(manager.renameProfile(named: name, to: "Renamed") == "Renamed")

        manager.setSlot(.a)
        #expect(manager.activeProfileName == "Renamed")
    }

    @Test func switchingToTheSlotAlreadyLiveDoesNothing() {
        let manager = makeManager()
        manager.setGain(3, forBandAt: 1)
        let before = manager.currentFilters

        manager.setSlot(.a)
        #expect(manager.abSlot == .a)
        #expect(manager.currentFilters == before)
    }

    // MARK: - Automatic gain

    @Test func turningAutoOnTakesTheTrimOverImmediately() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setAutoGain(false)
        for slot in 0..<BuiltInProfiles.bandCount { manager.setGain(6, forBandAt: slot) }
        #expect(manager.currentPreamp == 0, "nothing should have touched the trim yet")

        manager.setAutoGain(true)
        #expect(manager.isAutoGain)
        #expect(manager.currentPreamp < -3, "auto did not pull the trim down for a lifted chain")
    }

    /// The trim has to follow the chain, or it is only right at the moment it is
    /// switched on.
    @Test func theComputedTrimFollowsEveryKindOfEdit() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setAutoGain(true)
        #expect(manager.currentPreamp.isClose(to: 0, within: 0.01))

        manager.setGain(9, forBandAt: 5)
        let afterBand = manager.currentPreamp
        #expect(afterBand < -0.5)

        manager.addFilter(kind: .highShelf, frequency: 8_000, gain: 8, q: 0.7)
        #expect(manager.currentPreamp < afterBand, "adding a boost did not deepen the trim")

        manager.setTone(bass: 6)
        #expect(manager.currentPreamp < afterBand)
    }

    /// Switching off has to be silent: the number stays where the computation
    /// left it, and only then becomes the user's again.
    @Test func turningAutoOffKeepsTheValueAndReturnsTheControl() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(8, forBandAt: 4)
        manager.setAutoGain(true)
        let computed = manager.currentPreamp

        manager.setAutoGain(false)
        #expect(!manager.isAutoGain)
        #expect(manager.currentPreamp == computed, "the trim jumped when auto was switched off")

        manager.setPreamp(-2)
        #expect(
            manager.currentPreamp == -2, "the slider did not come back under the user's control")
    }

    /// While auto is on the slider is disabled, so a write can only arrive from
    /// a caller that has not looked — and it must not be honoured.
    @Test func theTrimCannotBeSetByHandWhileAutoIsOn() {
        let manager = makeManager()
        manager.setGain(6, forBandAt: 0)
        manager.setAutoGain(true)
        let computed = manager.currentPreamp

        manager.setPreamp(11)
        #expect(manager.currentPreamp == computed)
    }

    /// The mode belongs to the sound, so it saves into the preset and comes back
    /// with it.
    @Test func autoIsSavedIntoThePresetAndRestoredWithIt() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(7, forBandAt: 2)
        manager.setAutoGain(true)
        let auto = manager.addProfile(named: "Auto Preset")
        manager.saveChangesToActiveProfile()
        #expect(manager.profile(named: auto)?.autoGain == true)

        // Every built-in computes its trim, so the preset that proves the mode
        // travels has to be one saved with it off.
        manager.setAutoGain(false)
        let manual = manager.addProfile(named: "Manual Preset")
        manager.saveChangesToActiveProfile()
        #expect(manager.profile(named: manual)?.autoGain == false)

        manager.setActiveProfile(name: auto)
        #expect(manager.isAutoGain, "the preset did not bring its mode back")

        manager.setActiveProfile(name: manual)
        #expect(!manager.isAutoGain, "a preset saved without auto did not turn it off")
    }

    @Test func autoSurvivesRelaunchAndIsRecomputed() {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.setGain(9, forBandAt: 6)
        first.setAutoGain(true)
        let computed = first.currentPreamp

        let second = makeManager()
        #expect(second.isAutoGain)
        #expect(second.currentPreamp.isClose(to: computed, within: 0.01))
    }

    /// The mode is part of the sound, so departing from the one the preset asks
    /// for has to report as edited. Every built-in computes its trim, so the
    /// departure is turning it off.
    @Test func changingTheAutoModeCountsAsAnEdit() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        #expect(!manager.isModified)

        manager.setAutoGain(false)
        #expect(manager.isModified)

        manager.setAutoGain(true)
        #expect(!manager.isModified, "returning to the preset's own mode is not an edit")
    }

    /// Each slot carries its own mode, so A can be computed while B is held.
    @Test func eachSlotCarriesItsOwnAutoSetting() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(8, forBandAt: 3)
        manager.setAutoGain(true)

        manager.setSlot(.b)
        manager.setAutoGain(false)
        manager.setPreamp(4)

        manager.setSlot(.a)
        #expect(manager.isAutoGain)
        #expect(manager.currentPreamp < 0)

        manager.setSlot(.b)
        #expect(!manager.isAutoGain)
        #expect(manager.currentPreamp == 4)
    }

    // MARK: - Persistence

    @Test func userProfilesSurviveRelaunch() {
        let first = makeManager()
        first.addProfile(named: "Kept")
        first.setGain(5, forBandAt: 0)
        first.saveChangesToActiveProfile()

        let second = makeManager()
        #expect(second.library.user.map(\.name) == ["Kept"])
        #expect(second.profile(named: "Kept")?.bandFilters[0].gain == 5)
    }

    @Test func unsavedFreeFiltersSurviveRelaunch() {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.addFilter(kind: .highPass, frequency: 40, gain: 0, q: 0.707)
        let expected = first.currentFilters

        let second = makeManager()
        #expect(second.currentFilters == expected)
        #expect(second.freeFilters.first?.kind == .highPass)
        #expect(second.isModified)
    }

    @Test func anUnmodifiedChainStoresNothing() throws {
        let manager = makeManager()
        let id = try #require(manager.addFilter(frequency: 180, gain: 4), "filter not added")
        #expect(storedState()?.filters != nil)

        manager.removeFilter(id: id)
        #expect(storedState()?.filters == nil, "back to the preset means nothing to remember")
    }

    @Test func profilesListsBuiltInsBeforeUserPresets() {
        let manager = makeManager()
        manager.addProfile(named: "Mine")

        #expect(manager.profiles.count == BuiltInProfiles.all.count + 1)
        #expect(manager.profiles.last?.name == "Mine")
        #expect(manager.profiles.first?.name == BuiltInProfiles.all[0].name)
    }
}
