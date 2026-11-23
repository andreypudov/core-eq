import Foundation
import Testing

/// A double-click on a parametric filter's node puts it back where the preset
/// has it, as a double-click on a band puts the band back — across a relaunch
/// as well as within one.
@MainActor final class ProfileManagerFilterResetTests {
    private let store: TemporaryDefaults
    private let settings: SettingsStore

    init() throws {
        store = try #require(TemporaryDefaults())
        settings = SettingsStore(defaults: store.values)
    }

    isolated deinit {
        store.remove()
    }

    private func makeManager() -> ProfileManager {
        ProfileManager(settings: settings, outputDeviceUID: "BuiltInSpeakerDevice")
    }

    /// Bass Booster's one parametric filter: a low shelf at 120 Hz, +4 dB.
    private func boosterShelf(_ manager: ProfileManager) throws -> EQFilter {
        try #require(manager.freeFilters.first)
    }

    @Test func aMovedNodeGoesBackToWhereThePresetHasIt() throws {
        let manager = makeManager()
        manager.setActiveProfile(name: "Bass Booster")
        let shelf = try boosterShelf(manager)

        manager.setFilterFrequency(300, id: shelf.id)
        manager.setFilterGain(-6, id: shelf.id)
        #expect(manager.isModified)

        manager.resetFilter(id: shelf.id)
        let reset = try boosterShelf(manager)
        #expect(reset.frequency == 120)
        #expect(reset.gain == 4)
        #expect(!manager.isModified)
    }

    /// Kind and Q are edited in the list, not by dragging the node, so the
    /// node's reset leaves them alone.
    @Test func resettingANodeLeavesKindAndQAsTheyAre() throws {
        let manager = makeManager()
        manager.setActiveProfile(name: "Bass Booster")
        let shelf = try boosterShelf(manager)

        manager.setFilterQ(2, id: shelf.id)
        manager.setFilterGain(-6, id: shelf.id)
        manager.resetFilter(id: shelf.id)

        let reset = try boosterShelf(manager)
        #expect(reset.gain == 4)
        #expect(reset.q == 2)
    }

    /// A filter added since the preset was selected has nowhere to go back to:
    /// 0 dB, where it stands.
    @Test func aFilterThePresetDoesNotHaveGoesToZero() throws {
        let manager = makeManager()
        manager.setActiveProfile(name: "Bass Booster")
        let added = try #require(manager.addFilter(frequency: 3_000, gain: 5))

        manager.resetFilter(id: added)
        let filter = try #require(manager.freeFilters.first { $0.id == added })
        #expect(filter.gain == 0)
        #expect(filter.frequency == 3_000)
    }

    /// The point of storing ids: the working chain and its preset still agree
    /// on them after a relaunch.
    @Test func aBuiltInPresetsNodeResetsAfterARelaunch() throws {
        let first = makeManager()
        first.setActiveProfile(name: "Bass Booster")
        first.setFilterGain(-6, id: try boosterShelf(first).id)

        let relaunched = makeManager()
        let shelf = try boosterShelf(relaunched)
        #expect(shelf.gain == -6, "the edit came back")

        relaunched.resetFilter(id: shelf.id)
        #expect(try boosterShelf(relaunched).gain == 4)
    }

    @Test func aUserPresetsNodeResetsAfterARelaunch() throws {
        let first = makeManager()
        let name = try #require(first.duplicateProfile(named: "Bass Booster"))
        first.setActiveProfile(name: name)
        first.setFilterGain(-6, id: try boosterShelf(first).id)

        let relaunched = makeManager()
        #expect(relaunched.activeProfileName == name)
        relaunched.resetFilter(id: try boosterShelf(relaunched).id)
        #expect(try boosterShelf(relaunched).gain == 4)
    }

    /// User presets written before ids were are rewritten once with ids, so
    /// they stop getting new ones on every launch.
    @Test func userPresetsStoredWithoutIDsAreRewrittenWithThem() throws {
        let booster = try #require(BuiltInProfiles.all.first { $0.name == "Bass Booster" })
        let legacy = EQProfile(name: "Mine", filters: booster.filters, preamp: 0)
        let encoder = JSONEncoder()
        encoder.userInfo[.omitsFilterIdentity] = true
        store.values.set(try encoder.encode([legacy]), forKey: "userProfiles")

        _ = makeManager()
        let first = try #require(settings.userProfiles.first?.filters.last)
        #expect(!first.hasGeneratedID, "written back with an id")

        _ = makeManager()
        let second = try #require(settings.userProfiles.first?.filters.last)
        #expect(second.id == first.id, "and the same one on the next launch")
    }

    /// A user preset whose name a built-in has since taken is hidden by the
    /// library, but it is still the user's: giving the presets ids must not
    /// delete it from disk.
    @Test func addingIDsKeepsAPresetTheLibraryHides() throws {
        let mine = EQProfile(name: "Rock", filters: BuiltInProfiles.emptyBandChain(), preamp: -1)
        let other = EQProfile(
            name: "Mine",
            filters: BuiltInProfiles.emptyBandChain() + [
                EQFilter(kind: .bell, frequency: 500, gain: 2, q: 1)
            ],
            preamp: 0)
        let encoder = JSONEncoder()
        encoder.userInfo[.omitsFilterIdentity] = true
        store.values.set(try encoder.encode([mine, other]), forKey: "userProfiles")

        _ = makeManager()
        #expect(settings.userProfiles.map(\.name) == ["Rock", "Mine"])
    }
}
