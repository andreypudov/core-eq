import Foundation
import Testing

/// A filter's `id`, which is how a parametric filter is found again in the
/// preset it came from.
///
/// A band has its slot for that. A free filter has only its id, so the id has
/// to survive everything between the preset and a double-click on the node:
/// saving, relaunching, normalising, and presets written before ids were.
struct FilterIdentityTests {
    private let shelf = EQFilter(kind: .lowShelf, frequency: 120, gain: 4, q: 0.7)
    private let bell = EQFilter(kind: .bell, frequency: 2_000, gain: -3, q: 2)

    /// The chain as stored before ids were: the same JSON without the key.
    private func withoutIdentity(_ filters: [EQFilter]) throws -> [EQFilter] {
        let encoder = JSONEncoder()
        encoder.userInfo[.omitsFilterIdentity] = true
        return try JSONDecoder().decode([EQFilter].self, from: encoder.encode(filters))
    }

    // MARK: - Storing

    /// A filter written before ids were gets one on loading, and says so: such
    /// an id is new on every launch until the filter is written again.
    @Test func aFilterStoredWithoutAnIDIsGivenOneAndMarked() throws {
        let decoded = try withoutIdentity([shelf])[0]

        #expect(decoded.hasGeneratedID)
        #expect(decoded.id != shelf.id)
        #expect(decoded == shelf, "the sound is unchanged")
    }

    /// A file that leaves this Mac carries no ids: they mean nothing next to
    /// someone else's presets.
    @Test func exportedPresetsCarryNoIdentifiers() throws {
        let profile = EQProfile(name: "Shared", filters: BuiltInProfiles.emptyBandChain() + [shelf])
        let json = try ParametricEQSerializer.serializeToCoreEQJSON(profile)

        #expect(!json.contains("\"id\""))
    }

    // MARK: - Built-in presets

    /// Built-ins are rebuilt on every launch. Their parametric filters have to
    /// come back with the same ids, or a working chain saved by the last launch
    /// would never match its preset.
    @Test func builtInFiltersHaveTheSameIdentityEveryLaunch() throws {
        let booster = try #require(BuiltInProfiles.all.first { $0.name == "Bass Booster" })
        let free = try #require(booster.filters.first { !$0.isBand })

        #expect(free.id == EQFilter.stableID("built-in/Bass Booster/0"))
    }

    @Test func stableIdentifiersDependOnlyOnTheirKey() {
        #expect(EQFilter.stableID("a") == EQFilter.stableID("a"))
        #expect(EQFilter.stableID("a") != EQFilter.stableID("b"))
    }

    /// Two built-ins can hold the same filter; their ids still differ, so a
    /// filter is only ever matched against its own preset's.
    @Test func noTwoBuiltInFiltersShareAnIdentity() {
        let ids = BuiltInProfiles.all.flatMap { $0.filters.filter { !$0.isBand }.map(\.id) }
        #expect(Set(ids).count == ids.count)
    }

    // MARK: - Normalising

    @Test func normalisingKeepsAFreeFiltersIdentity() {
        let chain = FilterChain.normalized(BuiltInProfiles.emptyBandChain() + [shelf, bell])
        #expect(chain.filter { !$0.isBand }.map(\.id) == [shelf.id, bell.id])
    }

    /// The list is keyed by id, so one id can never be in a chain twice.
    @Test func normalisingGivesADuplicateIdentityANewOne() {
        let copy = bell.identified(as: shelf.id)
        let ids = FilterChain.normalized([shelf, copy]).filter { !$0.isBand }.map(\.id)

        #expect(ids.count == 2)
        #expect(ids[0] == shelf.id)
        #expect(ids[1] != shelf.id)
    }

    // MARK: - Chains saved before ids

    /// A working chain from an earlier version takes its preset's ids, matched
    /// by position, so its nodes reset to the preset rather than to 0 dB.
    @Test func aChainSavedWithoutIDsAdoptsItsPresetsIdentities() throws {
        let preset = BuiltInProfiles.emptyBandChain() + [shelf, bell]
        var edited = try withoutIdentity([shelf, bell])
        edited[0].gain = 9

        let adopted = FilterChain.adoptingIdentity(
            of: preset, into: BuiltInProfiles.emptyBandChain() + edited)
        let free = adopted.filter { !$0.isBand }

        #expect(free.map(\.id) == [shelf.id, bell.id])
        #expect(free[0].gain == 9, "the edit is kept")
        #expect(!free.contains { $0.hasGeneratedID })
    }

    /// Matching by position is only safe when nothing was added or removed.
    @Test func aChainWithADifferentCountKeepsItsOwnIdentities() throws {
        let preset = BuiltInProfiles.emptyBandChain() + [shelf, bell]
        let edited = BuiltInProfiles.emptyBandChain() + (try withoutIdentity([shelf]))

        let adopted = FilterChain.adoptingIdentity(of: preset, into: edited)
        #expect(adopted.filter { !$0.isBand }.map(\.id) == edited.filter { !$0.isBand }.map(\.id))
    }

    /// Nor when the kinds no longer line up: that is a different filter.
    @Test func aChainWhoseKindsDifferKeepsItsOwnIdentities() throws {
        let preset = BuiltInProfiles.emptyBandChain() + [shelf, bell]
        let edited = BuiltInProfiles.emptyBandChain() + (try withoutIdentity([bell, shelf]))

        let adopted = FilterChain.adoptingIdentity(of: preset, into: edited)
        #expect(!adopted.filter { !$0.isBand }.map(\.id).contains(shelf.id))
    }

    /// A chain whose ids were stored is already matched; nothing is re-guessed.
    @Test func aChainWithStoredIDsIsLeftAlone() {
        let preset = BuiltInProfiles.emptyBandChain() + [shelf]
        let own = EQFilter(kind: .lowShelf, frequency: 120, gain: 4, q: 0.7)
        let chain = BuiltInProfiles.emptyBandChain() + [own]

        let adopted = FilterChain.adoptingIdentity(of: preset, into: chain)
        #expect(adopted.last?.id == own.id)
    }
}
