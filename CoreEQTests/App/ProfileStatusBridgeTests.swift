import Foundation
import Testing

/// What the diagnostics report is told about the profile manager.
///
/// This bridge exists because a preset coming back wrong has two very different
/// causes — the device list never noticed the change, or the EQ never followed
/// it — and they need different fixes. The report can only tell them apart if
/// what is recorded here stays faithful.
@MainActor final class ProfileStatusBridgeTests {
    private let store: TemporaryDefaults
    private let settings: SettingsStore

    init() throws {
        store = try #require(TemporaryDefaults())
        settings = SettingsStore(defaults: store.values)
    }

    isolated deinit {
        store.remove()
    }

    private static let speakers = "BuiltInSpeakerDevice"
    private static let blackHole = "BlackHole16ch"

    // MARK: - What the device list reported

    @Test func nothingIsRecordedBeforeTheListReports() {
        let bridge = ProfileStatusBridge()

        #expect(bridge.deviceListUID == nil)
        #expect(bridge.deviceListUpdates == 0)
    }

    /// A count stuck at one while the system default has moved is the evidence
    /// that the list never noticed, so every change has to move it.
    @Test func everyReportedChangeIsCounted() {
        let bridge = ProfileStatusBridge()

        bridge.noteDeviceList(uid: Self.speakers)
        bridge.noteDeviceList(uid: Self.blackHole)

        #expect(bridge.deviceListUID == Self.blackHole)
        #expect(bridge.deviceListUpdates == 2)
    }

    /// Counting is unconditional here.
    ///
    /// Repeats are dropped upstream, in `OutputDeviceFollower`, so anything that
    /// reaches this point is a change worth counting. Adding a second guard
    /// would look like a tidy-up and would hide a real fault: a list reporting
    /// the same device while the system default has moved elsewhere is exactly
    /// the stale-list case this number exists to expose.
    @Test func aRepeatedDeviceStillCountsWhenItGetsHere() {
        let bridge = ProfileStatusBridge()

        bridge.noteDeviceList(uid: Self.speakers)
        bridge.noteDeviceList(uid: Self.speakers)

        #expect(bridge.deviceListUpdates == 2)
    }

    /// Losing the output is something the list reported, not something it
    /// failed to report.
    @Test func theAbsenceOfADeviceIsRecorded() {
        let bridge = ProfileStatusBridge()

        bridge.noteDeviceList(uid: Self.speakers)
        bridge.noteDeviceList(uid: nil)

        #expect(bridge.deviceListUID == nil)
        #expect(bridge.deviceListUpdates == 2)
    }

    // MARK: - What the manager actually holds

    @Test func theLiveProfileIsMirroredOnceFollowed() {
        let bridge = ProfileStatusBridge()
        let manager = ProfileManager(settings: settings, outputDeviceUID: Self.speakers)

        bridge.follow(manager)

        #expect(bridge.activeProfileName == manager.activeProfileName)
        #expect(bridge.abSlot == manager.abSlot)
        #expect(bridge.outputDeviceUID == Self.speakers)
    }

    /// The device the manager is filing under is read when the profile name
    /// changes rather than published on its own. That only works because every
    /// device change republishes the name — if it ever stops doing so, the
    /// report starts naming the wrong slot, and this is what says so.
    @Test func theDeviceFiledUnderFollowsASwitch() {
        let bridge = ProfileStatusBridge()
        let manager = ProfileManager(settings: settings, outputDeviceUID: Self.speakers)
        bridge.follow(manager)

        manager.setOutputDevice(uid: Self.blackHole)

        #expect(
            bridge.outputDeviceUID == Self.blackHole,
            "the report would name the device the user just left")
    }

    /// The A/B slot is the other half of what a report compares against the
    /// stored state, and it moves without the device moving.
    @Test func theSlotOnScreenIsMirrored() {
        let bridge = ProfileStatusBridge()
        let manager = ProfileManager(settings: settings, outputDeviceUID: Self.speakers)
        bridge.follow(manager)

        manager.setSlot(.b)

        #expect(bridge.abSlot == manager.abSlot)
    }

    /// A bridge that was never pointed at a manager reports nothing rather than
    /// something stale — the Settings scene builds on its own schedule and can
    /// draw a report before the app delegate has wired anything up.
    @Test func anUnfollowedBridgeHoldsNothing() {
        let bridge = ProfileStatusBridge()

        #expect(bridge.activeProfileName == nil)
        #expect(bridge.abSlot == nil)
        #expect(bridge.outputDeviceUID == nil)
    }
}
