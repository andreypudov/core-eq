import Foundation
import Testing

/// Everything the app remembers between launches passes through here, so a
/// silent failure in this file is a user's presets and per-device state
/// disappearing.
@MainActor final class SettingsStoreTests {
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

    /// What a first launch sees. Every one of these is a decision: the
    /// equalizer starts on, and nothing else is remembered yet.
    @Test func aFreshInstallStartsEmptyAndEnabled() {
        #expect(settings.isEnabled, "the equalizer should be on the first time it is opened")
        #expect(settings.activeProfileName == nil)
        #expect(settings.workingFilters == nil)
        #expect(settings.workingPreamp == nil)
        #expect(settings.tone == nil)
        #expect(settings.legacyCustomGains == nil)
        #expect(settings.userProfiles.isEmpty)
        #expect(settings.deviceStates.isEmpty)
    }

    @Test func theEnabledFlagRoundTrips() {
        settings.isEnabled = false
        #expect(!SettingsStore(defaults: defaults).isEnabled)

        settings.isEnabled = true
        #expect(SettingsStore(defaults: defaults).isEnabled)
    }

    @Test func userProfilesRoundTrip() {
        let profile = EQProfile(
            name: "Late Night",
            filters: BuiltInProfiles.emptyBandChain() + [
                EQFilter(kind: .lowShelf, frequency: 120, gain: -3, q: 0.7, colorIndex: 2)
            ],
            preamp: -2.5
        )
        settings.userProfiles = [profile]

        let restored = SettingsStore(defaults: defaults).userProfiles
        #expect(restored.count == 1)
        #expect(restored.first?.name == "Late Night")
        #expect(restored.first?.preamp == -2.5)
        #expect(restored.first?.filters == profile.filters)
        #expect(
            restored.first?.freeFilters.first?.colorIndex == 2,
            "a band's colour is part of the preset")
    }

    /// The per-device slots are the whole point of `DeviceEQState`: two devices
    /// must not share a key, and each must come back as it went in.
    @Test func deviceStatesRoundTripPerDevice() {
        var chain = BuiltInProfiles.emptyBandChain()
        chain[0].gain = 6
        settings.deviceStates = [
            "speakers": DeviceEQState(
                profileName: "Rock", filters: chain, preamp: -1, tone: [1, 0, -1]),
            "headphones": DeviceEQState(profileName: "Jazz"),
        ]

        let restored = SettingsStore(defaults: defaults).deviceStates
        #expect(restored.count == 2)
        #expect(restored["speakers"]?.profileName == "Rock")
        #expect(restored["speakers"]?.preamp == -1)
        #expect(restored["speakers"]?.tone == [1, 0, -1])
        #expect(restored["speakers"]?.filters?.first?.gain == 6)
        #expect(restored["headphones"]?.profileName == "Jazz")
        #expect(restored["headphones"]?.filters == nil, "an unedited device stores no chain")
    }

    /// The no-device case is filed under the empty string, which no real UID
    /// can collide with — so it has to survive as a key.
    @Test func theNoDeviceSlotIsAValidKey() {
        settings.deviceStates = ["": DeviceEQState(profileName: "Flat", preamp: 3)]
        #expect(SettingsStore(defaults: defaults).deviceStates[""]?.preamp == 3)
    }

    /// Each legacy key can be written back as nil, because migration consumes
    /// them: a key that would not clear would migrate on every launch.
    @Test func legacyKeysCanBeCleared() {
        settings.activeProfileName = "Rock"
        settings.workingFilters = BuiltInProfiles.emptyBandChain()
        settings.workingPreamp = -3
        settings.tone = [1, 2, 3]
        settings.legacyCustomGains = Array(repeating: 2.0, count: BuiltInProfiles.bandCount)

        settings.activeProfileName = nil
        settings.workingFilters = nil
        settings.workingPreamp = nil
        settings.tone = nil
        settings.legacyCustomGains = nil

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.activeProfileName == nil)
        #expect(reopened.workingFilters == nil)
        #expect(reopened.workingPreamp == nil)
        #expect(reopened.tone == nil)
        #expect(reopened.legacyCustomGains == nil)
    }

    /// Defaults are shared with anything else on the machine, and a corrupt or
    /// foreign value must not take the app down with it.
    @Test func rubbishInDefaultsIsIgnoredRatherThanFatal() {
        defaults.set("not a profile at all", forKey: "userProfiles")
        defaults.set(Data([0x00, 0x01]), forKey: "deviceStates")

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.userProfiles.isEmpty)
        #expect(reopened.deviceStates.isEmpty)
    }
    /// On unless the user says otherwise. The default matters: it decides
    /// whether a Mac that has played anything once ever sleeps again.
    @Test func releasingTheDeviceIsOnByDefault() {
        #expect(settings.pausesWhenSilent)
    }

    @Test func theIdleSettingSurvivesARelaunch() {
        settings.pausesWhenSilent = false
        #expect(SettingsStore(defaults: defaults).pausesWhenSilent == false)
    }

}
