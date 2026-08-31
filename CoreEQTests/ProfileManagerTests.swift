import Foundation
import Testing

@MainActor final class ProfileManagerTests {
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

    // MARK: - Surviving a relaunch

    private static let speakers = "BuiltInSpeakerDevice"
    private static let aggregate = "~:AMS2_Aggregate:0"

    /// Edit on one device, switch away, then relaunch with that device already
    /// default. The edit has to be there.
    @Test func anEditSurvivesASwitchAndARelaunch() {
        let first = makeManager(device: Self.speakers)
        first.setGain(9, forBandAt: 0)
        first.setOutputDevice(uid: Self.aggregate)

        let second = makeManager(device: Self.speakers)
        #expect(second.bandFilters[0].gain == 9, "the edit did not survive the relaunch")
    }

    /// The same edit, reached by relaunching on the other device and switching
    /// back — the sequence that was reported as the one that does work.
    @Test func anEditComesBackWhenSwitchingToItsDevice() {
        let first = makeManager(device: Self.speakers)
        first.setGain(9, forBandAt: 0)
        first.setOutputDevice(uid: Self.aggregate)

        let second = makeManager(device: Self.aggregate)
        second.setOutputDevice(uid: Self.speakers)
        #expect(second.bandFilters[0].gain == 9, "the edit did not come back on switching")
    }

    /// Quitting is not a device change, so an edit has to be filed when it is
    /// made rather than when the device next changes.
    @Test func anEditIsFiledWithoutADeviceSwitch() {
        let first = makeManager(device: Self.speakers)
        first.setGain(7, forBandAt: 0)

        let second = makeManager(device: Self.speakers)
        #expect(second.bandFilters[0].gain == 7, "the edit was never filed")
    }

    // MARK: - A/B belongs to its device

    /// The reported fault: A and B set up on one device appeared on the next.
    ///
    /// Both slots are per device — "a comparison set up on headphones should
    /// still be there when headphones come back" — so arriving at a device must
    /// bring that device's pair, never the previous one's.
    @Test func bothSlotsBelongToTheirOwnDevice() {
        let manager = makeManager(device: Self.speakers)

        // A distinctive A, then a distinctive B, on the speakers.
        manager.setGain(9, forBandAt: 0)
        manager.setSlot(.b)
        manager.setGain(-9, forBandAt: 0)

        manager.setOutputDevice(uid: Self.aggregate)

        #expect(manager.abSlot == .a, "the previous device's live slot came along")
        #expect(
            manager.bandFilters[0].gain == 0,
            "the previous device's live slot content came along")

        manager.setSlot(.b)
        #expect(
            manager.bandFilters[0].gain == 0,
            "the previous device's alternate slot came along")
    }

    /// And the pair the first device had is still its own on return.
    @Test func aDevicesPairSurvivesAVisitToAnother() {
        let manager = makeManager(device: Self.speakers)
        manager.setGain(9, forBandAt: 0)
        manager.setSlot(.b)
        manager.setGain(-9, forBandAt: 0)

        manager.setOutputDevice(uid: Self.aggregate)
        manager.setGain(3, forBandAt: 0)
        manager.setOutputDevice(uid: Self.speakers)

        #expect(manager.abSlot == .b, "the live slot was not restored")
        #expect(manager.bandFilters[0].gain == -9, "slot B was not restored")

        manager.setSlot(.a)
        #expect(manager.bandFilters[0].gain == 9, "slot A was not restored")
    }

    /// A device never seen before starts at the default, not at whatever the
    /// last device happened to be playing.
    @Test func anUnknownDeviceStartsFresh() {
        let manager = makeManager(device: Self.speakers)
        manager.setGain(9, forBandAt: 0)
        manager.setSlot(.b)
        manager.setGain(-9, forBandAt: 0)

        manager.setOutputDevice(uid: "SomeDeviceNeverSeenBefore")

        #expect(manager.activeProfileName == BuiltInProfiles.defaultProfileName)
        #expect(manager.abSlot == .a)
        #expect(manager.bandFilters[0].gain == 0)
    }

    // MARK: - Surviving a relaunch

    /// The live slot is half the state: the same preset in the other slot is a
    /// different sound, so a relaunch that forgets which was live is wrong even
    /// when both slots survive.
    @Test func theLiveSlotSurvivesARelaunch() {
        let first = makeManager(device: Self.speakers)
        first.setGain(9, forBandAt: 0)
        first.setSlot(.b)
        first.setGain(-9, forBandAt: 0)

        let second = makeManager(device: Self.speakers)
        #expect(second.abSlot == .b, "the live slot was not restored")
        #expect(second.bandFilters[0].gain == -9, "the live slot's content was not restored")
    }

    /// The slot that is not being heard has to survive too, or A/B comes back
    /// as a comparison against nothing.
    @Test func theAlternateSlotSurvivesARelaunch() {
        let first = makeManager(device: Self.speakers)
        first.setGain(9, forBandAt: 0)
        first.setSlot(.b)
        first.setGain(-9, forBandAt: 0)

        let second = makeManager(device: Self.speakers)
        second.setSlot(.a)
        #expect(second.bandFilters[0].gain == 9, "the alternate slot was not restored")
    }

    /// Relaunching on a different device must not hand it the last session's
    /// pair — the same leak as switching, but across a launch.
    @Test func aRelaunchOnAnotherDeviceDoesNotInheritThePair() {
        let first = makeManager(device: Self.speakers)
        first.setGain(9, forBandAt: 0)
        first.setSlot(.b)
        first.setGain(-9, forBandAt: 0)

        let second = makeManager(device: Self.aggregate)
        #expect(second.abSlot == .a)
        #expect(second.bandFilters[0].gain == 0)
    }

    // MARK: - Remembering the device across launches

    /// Core Audio can have no answer at launch. Without a remembered device the
    /// session files everything into the no-device slot, where no real device
    /// ever reads it again.
    @Test func aLaunchWithNoDeviceFallsBackToTheLastOne() {
        let first = makeManager(device: Self.speakers)
        first.setGain(9, forBandAt: 0)
        first.setSlot(.b)
        first.setGain(-9, forBandAt: 0)

        // The system has not named a device yet.
        let second = makeManager(device: nil)

        #expect(second.outputDeviceUID == Self.speakers, "the last device was not remembered")
        #expect(second.abSlot == .b, "the live slot was lost with the device")
        #expect(second.bandFilters[0].gain == -9, "the state was lost with the device")
    }

    /// The remembered device follows the switches, so it is the one the user was
    /// actually last on rather than the one they started on.
    @Test func theRememberedDeviceFollowsSwitches() {
        let first = makeManager(device: Self.speakers)
        first.setOutputDevice(uid: Self.aggregate)
        first.setGain(4, forBandAt: 0)

        let second = makeManager(device: nil)

        #expect(second.outputDeviceUID == Self.aggregate)
        #expect(second.bandFilters[0].gain == 4)
    }

    /// A first ever launch has nothing to remember, and must not invent one.
    @Test func aFirstLaunchWithNoDeviceIsStillTheNoDeviceSlot() {
        let manager = makeManager(device: nil)

        #expect(manager.outputDeviceUID == nil)
        #expect(manager.activeProfileName == BuiltInProfiles.defaultProfileName)
    }

    /// A real device still wins over the remembered one: the point is a
    /// fallback, not a preference.
    @Test func aNamedDeviceWinsOverTheRememberedOne() {
        let first = makeManager(device: Self.speakers)
        first.setGain(9, forBandAt: 0)

        let second = makeManager(device: Self.aggregate)

        #expect(second.outputDeviceUID == Self.aggregate)
        #expect(second.bandFilters[0].gain == 0, "the remembered device's state was loaded")
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

    // MARK: - Launch state

    @Test func startsOnTheDefaultProfile() {
        let manager = makeManager()
        #expect(manager.activeProfileName == BuiltInProfiles.defaultProfileName)
        #expect(!manager.isModified)
    }

    @Test func restoresTheSavedSelection() {
        seed(DeviceEQState(profileName: "Jazz"))
        #expect(makeManager().activeProfileName == "Jazz")
    }

    @Test func fallsBackWhenTheSavedSelectionIsGone() {
        seed(DeviceEQState(profileName: "A Preset That Was Deleted"))
        #expect(makeManager().activeProfileName == BuiltInProfiles.defaultProfileName)
    }

    /// The chain is always eleven ladder filters followed by the free ones, so
    /// the slider strip can index straight into it no matter what was stored.
    @Test func chainIsNormalisedOnLaunch() {
        let manager = makeManager()
        #expect(manager.bandFilters.count == BuiltInProfiles.bandCount)
        #expect(manager.bandFilters.map(\.band) == Array(0..<BuiltInProfiles.bandCount))
        #expect(manager.freeFilters.isEmpty)
    }

    @Test func restoresTheWorkingChain() {
        var chain = BuiltInProfiles.emptyBandChain()
        for slot in chain.indices { chain[slot].gain = 3 }
        chain.append(EQFilter(kind: .lowShelf, frequency: 180, gain: -4, q: 0.8))
        seed(DeviceEQState(profileName: "Flat", filters: chain))

        let manager = makeManager()
        #expect(manager.bandFilters.allSatisfy { $0.gain == 3 })
        #expect(manager.freeFilters.count == 1)
        #expect(manager.freeFilters[0].kind == .lowShelf)
        #expect(manager.isModified)
    }

    /// Slider tweaks saved by CoreEQ 1.x are carried over once, so an update
    /// doesn't silently discard what the user was listening to.
    @Test func migratesLegacyCustomGains() {
        settings.activeProfileName = "Flat"
        settings.legacyCustomGains = Array(repeating: 3.0, count: BuiltInProfiles.bandCount)

        let manager = makeManager()
        #expect(manager.bandFilters.allSatisfy { $0.gain == 3.0 })
        #expect(manager.isModified)
        #expect(
            settings.legacyCustomGains == nil,
            "the legacy key is consumed, not left to fight the new one")
        #expect(storedState()?.filters != nil, "the migrated chain lands in the device's slot")
    }

    @Test func ignoresLegacyCustomGainsOfTheWrongLength() {
        settings.activeProfileName = "Flat"
        settings.legacyCustomGains = [1, 2, 3]

        #expect(!makeManager().isModified)
    }

    /// A preset saved under an older band ladder must adopt the current one,
    /// or its sliders would be labelled differently from every other preset.
    @Test func storedProfilesAreAlignedToTheCurrentLadder() {
        var stale = EQProfile(
            name: "Stale",
            filters: (0..<BuiltInProfiles.bandCount).map { EQFilter.band(slot: $0, gain: 1) }
        )
        stale.filters[stale.filters.count - 2].frequency = 15_000  // the old value
        settings.userProfiles = [stale]

        let restored = makeManager().library.user[0]
        #expect(restored.bandFilters.map(\.frequency) == BuiltInProfiles.frequencies)
        #expect(restored.bandFilters.allSatisfy { $0.gain == 1 }, "alignment must preserve gains")
    }

    @Test func storedProfileWithMissingBandsIsFilledOutToTheLadder() {
        settings.userProfiles = [
            EQProfile(name: "Short", filters: [EQFilter.band(slot: 0, gain: 2)])
        ]

        let restored = makeManager().library.user[0]
        #expect(restored.filters.count == BuiltInProfiles.bandCount)
        #expect(restored.bandFilters[0].gain == 2)
        #expect(restored.bandFilters.dropFirst().allSatisfy { $0.gain == 0 })
    }

    @Test func storedFreeFiltersArePreservedAndCapped() {
        let free = (0..<(BuiltInProfiles.maxFreeFilters + 5)).map {
            EQFilter(frequency: Double(100 + $0 * 10), gain: 1, q: 1)
        }
        settings.userProfiles = [
            EQProfile(name: "Many", filters: BuiltInProfiles.emptyBandChain() + free)
        ]

        let restored = makeManager().library.user[0]
        #expect(restored.freeFilters.count == BuiltInProfiles.maxFreeFilters)
    }

    @Test func storedProfileCollidingWithABuiltInIsDropped() {
        settings.userProfiles = [EQProfile(name: "Jazz", filters: BuiltInProfiles.all[0].filters)]
        #expect(makeManager().library.user.isEmpty)
    }

    // MARK: - Creating and naming

    @Test func addedProfileBecomesActiveAndAwaitsRename() {
        let manager = makeManager()
        let name = manager.addProfile()

        #expect(manager.activeProfileName == name)
        #expect(manager.profileAwaitingRename == name)
        #expect(manager.canEditProfile(named: name))
    }

    @Test func namesAreMadeUnique() {
        let manager = makeManager()
        #expect(manager.addProfile(named: "Mine") == "Mine")
        #expect(manager.addProfile(named: "Mine") == "Mine 2")
        #expect(manager.addProfile(named: "Mine") == "Mine 3")
    }

    @Test func newNameCannotCollideWithABuiltIn() {
        #expect(makeManager().addProfile(named: "Rock") == "Rock 2")
    }

    @Test func duplicateCopiesTheChainOfABuiltIn() {
        let manager = makeManager()
        let copy = manager.duplicateProfile(named: "Jazz")

        #expect(copy == "Jazz copy")
        #expect(
            manager.profile(named: "Jazz copy")?.filters == manager.profile(named: "Jazz")?.filters)
    }

    @Test func renameKeepsTheProfileActive() {
        let manager = makeManager()
        let original = manager.addProfile(named: "Before")

        #expect(manager.renameProfile(named: original, to: "After") == "After")
        #expect(manager.activeProfileName == "After")
    }

    @Test func renameRejectsEmptyNames() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Keep")

        #expect(manager.renameProfile(named: name, to: "   ") == nil)
        #expect(manager.activeProfileName == "Keep")
    }

    @Test func renameToATakenNameGetsASuffix() {
        let manager = makeManager()
        manager.addProfile(named: "Taken")
        let other = manager.addProfile(named: "Other")

        #expect(manager.renameProfile(named: other, to: "Taken") == "Taken 2")
    }

    @Test func builtInsCannotBeRenamedOrEdited() {
        let manager = makeManager()
        #expect(!manager.canEditProfile(named: "Rock"))
        #expect(manager.renameProfile(named: "Rock", to: "My Rock") == nil)

        manager.beginRename(of: "Rock")
        #expect(manager.profileAwaitingRename == nil)
    }

    // MARK: - Deleting

    @Test func deletingTheActiveProfileFallsBackToItsNeighbour() {
        let manager = makeManager()
        manager.addProfile(named: "First")
        let second = manager.addProfile(named: "Second")
        manager.addProfile(named: "Third")

        manager.setActiveProfile(name: second)
        manager.deleteProfile(named: second)

        #expect(manager.activeProfileName == "Third")
    }

    @Test func deletingTheLastUserProfileFallsBackToTheDefault() {
        let manager = makeManager()
        let only = manager.addProfile(named: "Only")
        manager.deleteProfile(named: only)

        #expect(manager.activeProfileName == BuiltInProfiles.defaultProfileName)
        #expect(manager.library.user.isEmpty)
    }

    @Test func deletingAnInactiveProfileLeavesTheSelectionAlone() {
        let manager = makeManager()
        let spare = manager.addProfile(named: "Spare")
        manager.setActiveProfile(name: "Jazz")

        manager.deleteProfile(named: spare)
        #expect(manager.activeProfileName == "Jazz")
    }

    @Test func deletingClearsAPendingRename() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Doomed")
        #expect(manager.profileAwaitingRename != nil)

        manager.deleteProfile(named: name)
        #expect(manager.profileAwaitingRename == nil)
    }

    // MARK: - Band editing

    @Test func setGainClampsToTheSliderRange() {
        let manager = makeManager()
        manager.setGain(99, forBandAt: 0)
        #expect(manager.bandFilters[0].gain == BuiltInProfiles.gainRange.upperBound)

        manager.setGain(-99, forBandAt: 0)
        #expect(manager.bandFilters[0].gain == BuiltInProfiles.gainRange.lowerBound)
    }

    @Test func setGainOutOfBoundsIsIgnored() {
        let manager = makeManager()
        let before = manager.currentFilters
        manager.setGain(3, forBandAt: 999)
        #expect(manager.currentFilters == before)
    }

    /// A slider must never reach a free filter, or the number over the knob
    /// would stop describing what the knob does.
    @Test func setGainCannotReachAFreeFilter() {
        let manager = makeManager()
        manager.addFilter(frequency: 180, gain: 5)
        manager.setGain(9, forBandAt: BuiltInProfiles.bandCount)

        #expect(manager.freeFilters[0].gain == 5)
    }

    @Test func resetBandRestoresTheProfileValue() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Jazz")
        let original = manager.bandFilters[2].gain

        manager.setGain(original + 5, forBandAt: 2)
        #expect(manager.isModified)

        manager.resetBand(at: 2)
        #expect(manager.bandFilters[2].gain == original)
        #expect(!manager.isModified)
    }

    @Test func resetToActiveProfileClearsEveryTweak() {
        let manager = makeManager()
        manager.setGain(7, forBandAt: 0)
        manager.addFilter(frequency: 180, gain: 3)

        manager.resetToActiveProfile()
        #expect(!manager.isModified)
        #expect(manager.freeFilters.isEmpty)
        #expect(storedState()?.filters == nil)
    }

    // MARK: - Free filters

    @Test func addingAFilterLeavesTheLadderAlone() {
        let manager = makeManager()
        let ladder = manager.bandFilters

        manager.addFilter(kind: .bell, frequency: 180, gain: 3, q: 0.8)

        #expect(manager.bandFilters == ladder, "no slider may move when a filter is added")
        #expect(manager.freeFilters.count == 1)
        #expect(manager.isModified)
    }

    @Test func addedFilterDefaultsToSilence() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.addFilter()

        // 0 dB is identity, so placing a filter is not yet an edit to the sound.
        #expect((total(manager.currentFilters, at: 1_000)).isClose(to: 0, within: 1e-9))
    }

    @Test func filterCountIsCapped() {
        let manager = makeManager()
        for _ in 0..<BuiltInProfiles.maxFreeFilters {
            #expect(manager.addFilter() != nil)
        }
        #expect(!manager.canAddFilter)
        #expect(manager.addFilter() == nil, "the render budget is a real limit")
        #expect(manager.freeFilters.count == BuiltInProfiles.maxFreeFilters)
    }

    @Test func filterParametersAreClamped() throws {
        let manager = makeManager()
        let id = try #require(manager.addFilter(), "filter not added")

        manager.setFilterFrequency(99_999, id: id)
        #expect(manager.freeFilters[0].frequency == BuiltInProfiles.filterFrequencyRange.upperBound)

        manager.setFilterQ(0, id: id)
        #expect(manager.freeFilters[0].q == BuiltInProfiles.filterQRange.lowerBound)

        manager.setFilterGain(99, id: id)
        #expect(manager.freeFilters[0].gain == BuiltInProfiles.gainRange.upperBound)
    }

    /// Colours are what tell one band's row and one node on the graph from
    /// another's, so bands added one after another must not arrive matching.
    @Test func addedFiltersTakeDistinctColours() {
        let manager = makeManager()
        for _ in 0..<EQFilter.colorCount {
            #expect(manager.addFilter() != nil)
        }

        let colors = manager.freeFilters.map(\.colorIndex)
        #expect(
            Set(colors).count == EQFilter.colorCount,
            "the palette is used up before any of it repeats")
    }

    /// A colour freed by a removal is the next one handed out, rather than the
    /// palette marching on and leaving gaps.
    @Test func aFreedColourIsReused() throws {
        let manager = makeManager()
        let first = try #require(manager.addFilter(), "the first filter was not added")
        try #require(manager.addFilter() != nil, "the second filter was not added")
        let freed = manager.freeFilters[0].colorIndex

        manager.removeFilter(id: first)
        #expect(manager.addFilter() != nil)
        #expect(manager.freeFilters.contains { $0.colorIndex == freed })
    }

    /// Colour is presentation, but it is presentation the user chose, so it has
    /// to survive the round trip through the device's stored state.
    @Test func filterColourSurvivesRelaunch() throws {
        let manager = makeManager()
        let id = try #require(manager.addFilter(), "filter not added")
        manager.setFilterColor(5, id: id)

        #expect(makeManager().freeFilters.first?.colorIndex == 5)
    }

    /// A band lifted out of the ladder joins bands that already have colours,
    /// so it needs one that isn't taken rather than the ladder's default.
    @Test func liftedBandTakesAnUnusedColour() {
        let manager = makeManager()
        manager.addFilter()
        #expect(manager.editBandAsFilter(slot: 4) != nil)

        #expect(Set(manager.freeFilters.map(\.colorIndex)).count == 2)
    }

    @Test func removingAFilterLeavesTheLadderIntact() throws {
        let manager = makeManager()
        let id = try #require(manager.addFilter(frequency: 180, gain: 4), "filter not added")

        manager.removeFilter(id: id)
        #expect(manager.freeFilters.isEmpty)
        #expect(manager.bandFilters.count == BuiltInProfiles.bandCount)
        #expect(!manager.isModified)
    }

    @Test func disablingAFilterRemovesItFromTheResponse() throws {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        let id = try #require(manager.addFilter(frequency: 1_000, gain: 6), "filter not added")
        #expect((total(manager.currentFilters, at: 1_000)).isClose(to: 6, within: 0.01))

        manager.setFilterEnabled(false, id: id)
        #expect((total(manager.currentFilters, at: 1_000)).isClose(to: 0, within: 1e-9))
    }

    /// A parametric band can still be taken out one at a time — that is the
    /// bypass that survived, and the useful one.
    @Test func aBandCanBeSwitchedOutOnItsOwn() throws {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setGain(6, forBandAt: 5)  // 1 kHz
        let id = try #require(manager.addFilter(frequency: 1_000, gain: 6), "not added")
        #expect((total(manager.currentFilters, at: 1_000)).isClose(to: 12, within: 0.01))

        manager.setFilterEnabled(false, id: id)
        #expect(
            (total(manager.currentFilters, at: 1_000)).isClose(to: 6, within: 0.01),
            "only the ladder remains")
    }

    /// The per-editor bypasses are gone, so a chain stored while one half was
    /// switched off has to come back audible — otherwise the update leaves a
    /// silent equalizer and no control that could explain it.
    @Test func aLadderStoredWhileBypassedComesBackOn() {
        var chain = BuiltInProfiles.emptyBandChain()
        for slot in chain.indices {
            chain[slot].gain = 4
            chain[slot].isEnabled = false
        }
        seed(DeviceEQState(profileName: "Flat", filters: chain))

        let manager = makeManager()
        #expect(
            manager.bandFilters.allSatisfy { $0.isEnabled }, "the ladder came back switched off")
        #expect(total(manager.currentFilters, at: 1_000) > 3)
    }

    /// The ladder is always exactly `bandCount` long, whatever has been done to
    /// the chain.
    ///
    /// The slider strip indexes straight into `bandFilters[slot]`, so a chain
    /// that ever came back short would be an out-of-range crash rather than a
    /// wrong number. `FilterChain.normalized` and `PresetLibrary` are what
    /// guarantee it; this is what would notice if either stopped.
    @Test func theLadderIsNeverShortWhateverHappensToTheChain() throws {
        let manager = makeManager()

        func check(_ what: String) {
            #expect(
                manager.bandFilters.count == BuiltInProfiles.bandCount,
                "the ladder is \(manager.bandFilters.count) long after \(what)")
        }

        check("launch")
        for profile in manager.profiles {
            manager.setActiveProfile(name: profile.name)
            check("selecting \(profile.name)")
        }

        manager.setGain(6, forBandAt: 0)
        check("a band edit")
        manager.setTone(bass: 8, mid: -4, treble: 3)
        check("the tone controls")
        _ = manager.addFilter()
        check("adding a filter")
        let lifted = try #require(manager.editBandAsFilter(slot: 2))
        check("lifting a band out")
        manager.removeFilter(id: lifted)
        check("putting it back")
        manager.setSlot(.b)
        check("switching to B")
        manager.resetToActiveProfile()
        check("a revert")

        // The same promise on the way in: a preset saved short must not be able
        // to shorten the strip.
        var short = EQProfile(name: "Short", filters: [EQFilter.band(slot: 0, gain: 4)])
        short.isBuiltIn = false
        settings.userProfiles = [short]
        let reloaded = makeManager()
        reloaded.setActiveProfile(name: "Short")
        #expect(reloaded.bandFilters.count == BuiltInProfiles.bandCount)
    }

    // MARK: - Global gain

    @Test func preampIsClampedAndCountsAsAnEdit() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        #expect(!manager.isModified)

        // The trim is only settable by hand once the computed mode is off.
        manager.setAutoGain(false)
        manager.setPreamp(99)
        #expect(manager.currentPreamp == BuiltInProfiles.preampRange.upperBound)
        #expect(manager.isModified, "the trim changes the sound, so it is an unsaved change")

        manager.setPreamp(-99)
        #expect(manager.currentPreamp == BuiltInProfiles.preampRange.lowerBound)
    }

    @Test func preampIsSavedIntoAndRestoredFromAPreset() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Trimmed")
        manager.setAutoGain(false)
        manager.setPreamp(-4.5)
        manager.saveChangesToActiveProfile()
        #expect(!manager.isModified)
        #expect(manager.profile(named: name)?.preamp == -4.5)

        manager.setActiveProfile(name: "Rock")
        #expect(manager.isAutoGain, "a built-in computes its own trim")
        #expect(manager.currentPreamp < 0, "Rock lifts the chain, so its trim pulls back")

        manager.setActiveProfile(name: name)
        #expect(manager.currentPreamp == -4.5)
    }

    @Test func preampSurvivesRelaunchAndRoundTripsThroughJSON() throws {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.setAutoGain(false)
        first.setPreamp(2.5)
        #expect(makeManager().currentPreamp == 2.5)

        let profile = EQProfile(name: "P", filters: BuiltInProfiles.emptyBandChain(), preamp: -6)
        let decoded = try JSONDecoder().decode(EQProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.preamp == -6)
    }

    @Test func resetToActiveProfileRestoresThePreamp() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        manager.setAutoGain(false)
        manager.setPreamp(-5)

        manager.resetToActiveProfile()
        #expect(manager.isAutoGain, "reset restores the preset's mode as well as its numbers")
        #expect(manager.currentPreamp == AutoGain.trim(for: manager.currentFilters))
        #expect(!manager.isModified)
    }

    // MARK: - Edit as filter

    /// A move, not a conversion: the lifted filter keeps every parameter, the
    /// slot stays in the strip at 0 dB, and the chain's response is unchanged.
    @Test func editBandAsFilterPreservesTheSound() throws {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        let before = manager.currentFilters
        let probes = [32.0, 125.0, 180.0, 1_000.0, 8_000.0, 16_000.0]
        let responseBefore = probes.map { total(before, at: $0) }

        let id = try #require(manager.editBandAsFilter(slot: 2), "band not lifted")

        for (probe, expected) in zip(probes, responseBefore) {
            #expect(
                (total(manager.currentFilters, at: probe)).isClose(to: expected, within: 1e-9),
                "the sound changed at \(probe) Hz")
        }

        #expect(
            manager.bandFilters.count == BuiltInProfiles.bandCount,
            "the ladder keeps its eleven sliders")
        #expect(manager.bandFilters[2].gain == 0, "the emptied slot is identity")
        let lifted = manager.freeFilters.first { $0.id == id }
        #expect(lifted?.frequency == BuiltInProfiles.frequencies[2])
        #expect(lifted?.q == BuiltInProfiles.defaultQ)
        #expect(lifted?.band == nil, "a lifted filter no longer belongs to a slot")
    }

    @Test func editBandAsFilterRefusesWhenFullRatherThanDroppingTheBand() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        for _ in 0..<BuiltInProfiles.maxFreeFilters { manager.addFilter() }
        let gain = manager.bandFilters[2].gain

        #expect(manager.editBandAsFilter(slot: 2) == nil)
        #expect(manager.bandFilters[2].gain == gain, "a refused lift must not empty the slot")
    }

    // MARK: - Presets replace the whole chain

    /// A preset is the complete sound, so selecting one clears free filters too.
    /// Otherwise "Flat" would mean flat plus whatever was left over.
    @Test func selectingAProfileReplacesTheWholeChain() {
        let manager = makeManager()
        manager.setGain(9, forBandAt: 0)
        manager.addFilter(frequency: 180, gain: 5)

        manager.setActiveProfile(name: "Rock")
        #expect(!manager.isModified)
        #expect(manager.currentFilters == manager.profile(named: "Rock")?.filters)
        // Rock ships with filters of its own, so "cleared" means the user's are
        // gone and only the preset's remain — not that there are none.
        #expect(
            !(manager.freeFilters.contains { $0.frequency == 180 }),
            "the filter the user added survived the preset switch")
        #expect(manager.freeFilters.count == manager.profile(named: "Rock")?.freeFilters.count)
    }

    @Test func flatIsFlat() {
        let manager = makeManager()
        manager.addFilter(frequency: 180, gain: 6)
        manager.setActiveProfile(name: "Flat")

        for probe in [32.0, 180.0, 1_000.0, 16_000.0] {
            #expect(
                (total(manager.currentFilters, at: probe)).isClose(to: 0, within: 1e-9),
                "at \(probe) Hz")
        }
    }

    @Test func saveChangesWritesTheWholeChainIntoTheProfile() {
        let manager = makeManager()
        let name = manager.addProfile(named: "Mine")
        manager.setGain(6, forBandAt: 3)
        manager.addFilter(kind: .highShelf, frequency: 8_000, gain: -2, q: 0.7)
        #expect(manager.isModified)

        manager.saveChangesToActiveProfile()
        #expect(!manager.isModified)
        #expect(manager.profile(named: name)?.bandFilters[3].gain == 6)
        #expect(manager.profile(named: name)?.freeFilters.count == 1)
        #expect(manager.profile(named: name)?.freeFilters.first?.kind == .highShelf)
    }

    @Test func saveChangesDoesNothingForABuiltIn() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Rock")
        manager.setGain(0, forBandAt: 0)

        manager.saveChangesToActiveProfile()
        #expect(
            manager.profile(named: "Rock")?.filters
                == BuiltInProfiles.all.first { $0.name == "Rock" }?.filters)
    }

    // MARK: - Quick EQ tone

    @Test func toneOffsetsAreLayeredOnTheActiveProfile() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.setTone(bass: 6)

        #expect(manager.bandFilters[0].gain > 0, "32 Hz should follow the bass control")
        #expect(manager.bandFilters.last?.gain == 0, "20 kHz should not")
    }

    /// The tone controls are a shortcut into the ladder, not into the chain.
    @Test func toneLeavesFreeFiltersAlone() {
        let manager = makeManager()
        manager.setActiveProfile(name: "Flat")
        manager.addFilter(frequency: 180, gain: 5)

        manager.setTone(bass: 6)
        #expect(manager.freeFilters.count == 1)
        #expect(manager.freeFilters[0].gain == 5)
    }

    @Test func toneIsClampedAndPersisted() {
        let manager = makeManager()
        manager.setTone(bass: 999)
        #expect(manager.tone.bass == QuickTone.range.upperBound)
        #expect(storedState()?.tone != nil)
    }

    @Test func selectingAProfileRecentresTone() {
        let manager = makeManager()
        manager.setTone(bass: 5, mid: -2)
        #expect(!manager.tone.isNeutral)

        manager.setActiveProfile(name: "Rock")
        #expect(manager.tone.isNeutral)
        #expect(storedState()?.tone == nil)
    }

    @Test func toneSurvivesRelaunch() {
        let first = makeManager()
        first.setActiveProfile(name: "Flat")
        first.setTone(treble: 4)
        let expected = first.currentFilters

        #expect(makeManager().currentFilters == expected)
    }

    // MARK: - Searching the library

    @Test func anEmptySearchReturnsEverythingInTwoGroups() {
        let manager = makeManager()
        manager.addProfile(named: "Mine")

        let all = manager.profiles(matching: "")
        #expect(all.builtIn.count == BuiltInProfiles.all.count)
        #expect(all.user.map(\.name) == ["Mine"])

        #expect(
            manager.profiles(matching: "   ").builtIn.count == BuiltInProfiles.all.count,
            "whitespace is not a search")
    }

    /// The word people remember is rarely the first one, so the match is on any
    /// part of the name.
    @Test func searchMatchesAnyPartOfTheName() {
        let manager = makeManager()
        let names = manager.profiles(matching: "boost").builtIn.map(\.name)

        #expect(names.contains("Bass Booster"))
        #expect(names.contains("Treble Booster"))
        #expect(!names.contains("Flat"))
    }

    @Test func searchIgnoresCaseAndDiacritics() {
        let manager = makeManager()
        manager.addProfile(named: "Café")

        #expect(manager.profiles(matching: "JAZZ").builtIn.map(\.name) == ["Jazz"])
        #expect(
            manager.profiles(matching: "cafe").user.map(\.name) == ["Café"],
            "a preset named Café has to answer to cafe")
    }

    @Test func searchKeepsTheUserGroupSeparate() {
        let manager = makeManager()
        manager.addProfile(named: "Rock Loud")

        let found = manager.profiles(matching: "rock")
        #expect(found.user.map(\.name) == ["Rock Loud"])
        #expect(found.builtIn.map(\.name) == ["Rock"])
    }

    @Test func searchCanMatchNothing() {
        let found = makeManager().profiles(matching: "zzzz")
        #expect(found.user.isEmpty)
        #expect(found.builtIn.isEmpty)
    }
}
