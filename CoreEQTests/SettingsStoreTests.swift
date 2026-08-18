import XCTest

/// Everything the app remembers between launches passes through here, so a
/// silent failure in this file is a user's presets and per-device state
/// disappearing.
@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUp() {
        super.setUp()
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

    /// What a first launch sees. Every one of these is a decision: the
    /// equalizer starts on, and nothing else is remembered yet.
    func testAFreshInstallStartsEmptyAndEnabled() {
        XCTAssertTrue(settings.isEnabled, "the equalizer should be on the first time it is opened")
        XCTAssertNil(settings.activeProfileName)
        XCTAssertNil(settings.workingFilters)
        XCTAssertNil(settings.workingPreamp)
        XCTAssertNil(settings.tone)
        XCTAssertNil(settings.legacyCustomGains)
        XCTAssertTrue(settings.userProfiles.isEmpty)
        XCTAssertTrue(settings.deviceStates.isEmpty)
    }

    func testTheEnabledFlagRoundTrips() {
        settings.isEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).isEnabled)

        settings.isEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).isEnabled)
    }

    func testUserProfilesRoundTrip() {
        let profile = EQProfile(
            name: "Late Night",
            filters: BuiltInProfiles.emptyBandChain() + [
                EQFilter(kind: .lowShelf, frequency: 120, gain: -3, q: 0.7, colorIndex: 2)
            ],
            preamp: -2.5
        )
        settings.userProfiles = [profile]

        let restored = SettingsStore(defaults: defaults).userProfiles
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.name, "Late Night")
        XCTAssertEqual(restored.first?.preamp, -2.5)
        XCTAssertEqual(restored.first?.filters, profile.filters)
        XCTAssertEqual(
            restored.first?.freeFilters.first?.colorIndex, 2,
            "a band's colour is part of the preset")
    }

    /// The per-device slots are the whole point of `DeviceEQState`: two devices
    /// must not share a key, and each must come back as it went in.
    func testDeviceStatesRoundTripPerDevice() {
        var chain = BuiltInProfiles.emptyBandChain()
        chain[0].gain = 6
        settings.deviceStates = [
            "speakers": DeviceEQState(
                profileName: "Rock", filters: chain, preamp: -1, tone: [1, 0, -1]),
            "headphones": DeviceEQState(profileName: "Jazz"),
        ]

        let restored = SettingsStore(defaults: defaults).deviceStates
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored["speakers"]?.profileName, "Rock")
        XCTAssertEqual(restored["speakers"]?.preamp, -1)
        XCTAssertEqual(restored["speakers"]?.tone, [1, 0, -1])
        XCTAssertEqual(restored["speakers"]?.filters?.first?.gain, 6)
        XCTAssertEqual(restored["headphones"]?.profileName, "Jazz")
        XCTAssertNil(restored["headphones"]?.filters, "an unedited device stores no chain")
    }

    /// The no-device case is filed under the empty string, which no real UID
    /// can collide with — so it has to survive as a key.
    func testTheNoDeviceSlotIsAValidKey() {
        settings.deviceStates = ["": DeviceEQState(profileName: "Flat", preamp: 3)]
        XCTAssertEqual(SettingsStore(defaults: defaults).deviceStates[""]?.preamp, 3)
    }

    /// Each legacy key can be written back as nil, because migration consumes
    /// them: a key that would not clear would migrate on every launch.
    func testLegacyKeysCanBeCleared() {
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
        XCTAssertNil(reopened.activeProfileName)
        XCTAssertNil(reopened.workingFilters)
        XCTAssertNil(reopened.workingPreamp)
        XCTAssertNil(reopened.tone)
        XCTAssertNil(reopened.legacyCustomGains)
    }

    /// Defaults are shared with anything else on the machine, and a corrupt or
    /// foreign value must not take the app down with it.
    func testRubbishInDefaultsIsIgnoredRatherThanFatal() {
        defaults.set("not a profile at all", forKey: "userProfiles")
        defaults.set(Data([0x00, 0x01]), forKey: "deviceStates")

        let reopened = SettingsStore(defaults: defaults)
        XCTAssertTrue(reopened.userProfiles.isEmpty)
        XCTAssertTrue(reopened.deviceStates.isEmpty)
    }
}
