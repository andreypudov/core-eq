import Foundation
import Testing

@MainActor final class ProfileManagerAuditionTests {
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

    private let device = "AuditionDevice"

    /// What was filed for a device, or for the no-device slot.
    private func storedState(device: String? = nil) -> DeviceEQState? {
        settings.deviceStates[device ?? ""]
    }

    /// A catalog-style profile: a couple of rungs moved plus one free filter,
    /// the shape an AutoEQ result arrives in. Computed trim is off so a test
    /// can name the exact preamp it expects.
    private func catalogProfile(
        named name: String = "HD 600",
        preamp: Double = -4.5
    ) -> EQProfile {
        var chain = BuiltInProfiles.emptyBandChain()
        chain[0].gain = 5
        chain[4].gain = -3
        chain.append(EQFilter(kind: .highShelf, frequency: 6_000, gain: 2.5, q: 0.7))
        return EQProfile(name: name, filters: chain, preamp: preamp, autoGain: false)
    }

    // MARK: - Beginning

    @Test func beginAuditionAppliesTheChainAndFlagsIt() {
        let manager = makeManager(device: device)
        #expect(!manager.isModified, "the default chain is not an edit")

        let profile = catalogProfile()
        manager.beginAudition(profile)

        #expect(manager.isAuditioning)
        #expect(manager.currentFilters == FilterChain.normalized(profile.filters))
        #expect(manager.currentPreamp == profile.preamp)
        #expect(manager.isAutoGain == profile.autoGain)
        #expect(
            !manager.isModified,
            "a preview must not read as an unsaved edit of the active preset")
        #expect(
            manager.activeProfileName == BuiltInProfiles.defaultProfileName,
            "a preview must not move the active selection")
    }

    @Test func beginAuditionDoesNotTouchPresetsOrTheDeviceSlot() {
        let manager = makeManager(device: device)
        manager.setGain(4, forBandAt: 0)
        let presetsBefore = settings.userProfiles
        let stateBefore = storedState(device: device)
        #expect(stateBefore != nil, "the setup edit was not filed")

        let profile = catalogProfile()
        manager.beginAudition(profile)

        #expect(settings.userProfiles == presetsBefore, "a preview is not a preset")
        #expect(manager.profile(named: profile.name) == nil, "the preview joined the library")
        #expect(
            storedState(device: device) == stateBefore,
            "the previewed chain leaked into the device's persisted slot")
    }

    // MARK: - Ending

    @Test func endAuditionRestoresTheWorkingStateExactly() {
        let manager = makeManager(device: device)
        manager.setActiveProfile(name: "Jazz")
        manager.setGain(5, forBandAt: 3)
        manager.setTone(bass: 4, mid: -2, treble: 1)
        manager.setAutoGain(false)
        manager.setPreamp(-2.5)

        let filtersBefore = manager.currentFilters
        let preampBefore = manager.currentPreamp
        let autoBefore = manager.isAutoGain
        let toneBefore = manager.tone
        let activeBefore = manager.activeProfileName
        let stateBefore = storedState(device: device)

        manager.beginAudition(catalogProfile())
        #expect(manager.currentFilters != filtersBefore, "the preview did not apply")
        #expect(manager.isAuditioning)

        manager.endAudition()

        #expect(!manager.isAuditioning)
        #expect(manager.currentFilters == filtersBefore)
        #expect(manager.currentPreamp == preampBefore)
        #expect(manager.isAutoGain == autoBefore)
        #expect(manager.tone == toneBefore)
        #expect(manager.activeProfileName == activeBefore)
        #expect(storedState(device: device) == stateBefore)
    }

    // MARK: - Saving

    @Test func saveAuditionAsPresetKeepsTheChainAndPersistsIt() throws {
        let manager = makeManager(device: device)
        let profile = catalogProfile(named: "HD 600")
        manager.beginAudition(profile)

        let name = try #require(manager.saveAuditionAsPreset())

        #expect(name == "HD 600")
        #expect(!manager.isAuditioning)
        #expect(manager.activeProfileName == name)
        #expect(manager.profile(named: name)?.filters == FilterChain.normalized(profile.filters))
        #expect(manager.profile(named: name)?.preamp == profile.preamp)
        #expect(manager.profile(named: name)?.autoGain == profile.autoGain)
        #expect(settings.userProfiles.map(\.name) == [name])

        // The slot now names the saved preset, and a fresh manager reads both
        // the preset and the selection back.
        #expect(storedState(device: device)?.profileName == name)
        let reloaded = ProfileManager(
            settings: SettingsStore(defaults: defaults), outputDeviceUID: device)
        #expect(reloaded.profile(named: name) != nil)
        #expect(reloaded.activeProfileName == name)
        #expect(reloaded.currentFilters == FilterChain.normalized(profile.filters))
    }

    @Test func saveAuditionAsPresetDoesNothingWhenNotAuditioning() {
        let manager = makeManager(device: device)
        #expect(manager.saveAuditionAsPreset() == nil)
        #expect(settings.userProfiles.isEmpty)
    }

    // MARK: - Switching mid-audition

    /// The snapshot is taken once, before the first preview, so previewing a
    /// second profile replaces the first rather than making it the thing to
    /// return to.
    @Test func switchingProfilesMidAuditionStillRestoresTheOriginalState() {
        let manager = makeManager(device: device)
        manager.setActiveProfile(name: "Rock")
        manager.setGain(-6, forBandAt: 2)

        let filtersBefore = manager.currentFilters
        let preampBefore = manager.currentPreamp
        let autoBefore = manager.isAutoGain
        let activeBefore = manager.activeProfileName

        manager.beginAudition(catalogProfile(named: "First", preamp: -3))
        manager.beginAudition(catalogProfile(named: "Second", preamp: -8))

        #expect(manager.currentFilters == FilterChain.normalized(catalogProfile().filters))
        #expect(
            manager.currentPreamp == -8,
            "the second preview should be the one on screen")

        manager.endAudition()

        #expect(manager.currentFilters == filtersBefore)
        #expect(manager.currentPreamp == preampBefore)
        #expect(manager.isAutoGain == autoBefore)
        #expect(manager.activeProfileName == activeBefore)
    }
}
