import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct AutoEQStoreTests {
    private func makeLoadedStore(cache: URL) async -> AutoEQStore {
        AutoEQTestFixtures.writeCache(into: cache)
        let service = AutoEQNetworkService(session: .autoEQStubbed(), cacheDirectory: cache)
        let store = AutoEQStore(service: service)
        await store.loadCatalog()
        return store
    }

    @Test func loadsCatalogFromCache() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        let store = await makeLoadedStore(cache: cache)

        #expect(store.catalogState == .loaded)
        #expect(store.models.count == 3)
        #expect(store.targets.count == 3)
    }

    @Test func selectModelDefaultsToFirstVariantAndRecommendedTarget() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        let store = await makeLoadedStore(cache: cache)

        store.selectModel(named: "Alpha Headphones")

        #expect(store.selectedModelName == "Alpha Headphones")
        #expect(store.selectedVariant?.source == "oratory1990")
        #expect(store.selectedVariant?.rig == "GRAS 43AG-7")
        // The recommended over-ear target outranks the merely compatible one.
        #expect(store.selectedTargetLabel == "Harman over-ear 2013")
        #expect(store.supportsCustomTargets)
        #expect(
            store.availableTargets.map(\.label) == [
                "Harman over-ear 2013", "Harman over-ear 2018",
            ])
    }

    @Test func formWideTargetIsOfferedForARiggedVariant() async throws {
        // Regression: a variant with a concrete rig must still see a target whose
        // compatibility entry has no rig. This is the common AutoEQ shape, and
        // exact rig equality left the target dropdown empty and disabled.
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        let entries = Data(
            """
            {"Alpha Headphones": [
              {"source": "oratory1990", "rig": "GRAS 45BC-10", "form": "over-ear"}
            ]}
            """.utf8)
        let targets = Data(
            """
            [{
              "label": "Harman over-ear 2018",
              "compatible": [{"source": "oratory1990", "form": "over-ear"}],
              "recommended": [],
              "bassBoost": {}
            }]
            """.utf8)
        AutoEQTestFixtures.writeCache(into: cache, entries: entries, targets: targets)
        let service = AutoEQNetworkService(session: .autoEQStubbed(), cacheDirectory: cache)
        let store = AutoEQStore(service: service)
        await store.loadCatalog()

        store.selectModel(named: "Alpha Headphones")

        #expect(store.selectedTargetLabel == "Harman over-ear 2018")
        #expect(store.availableTargets.map(\.label) == ["Harman over-ear 2018"])
        #expect(store.supportsCustomTargets)
    }

    @Test func selectVariantReDefaultsIncompatibleTarget() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        let store = await makeLoadedStore(cache: cache)
        store.selectModel(named: "Alpha Headphones")

        let crinacle = AutoEQVariant(source: "crinacle", rig: nil, form: "in-ear")
        store.selectVariant(crinacle)

        #expect(store.selectedVariant == crinacle)
        #expect(store.selectedTargetLabel == "Harman in-ear 2019")
        // A `nil` rig cannot use AutoEQ's equalize endpoint.
        #expect(!store.supportsCustomTargets)
    }

    @Test func selectVariantKeepsCompatibleTarget() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        let store = await makeLoadedStore(cache: cache)
        store.selectModel(named: "Alpha Headphones")
        store.selectTarget(label: "Harman over-ear 2018")

        store.selectVariant(
            AutoEQVariant(source: "oratory1990", rig: "GRAS 43AG-7", form: "over-ear"))

        #expect(store.selectedTargetLabel == "Harman over-ear 2018")
    }

    @Test func selectModelIgnoresUnknownName() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        let store = await makeLoadedStore(cache: cache)

        store.selectModel(named: "Nonexistent")

        #expect(store.selectedModelName == nil)
        #expect(store.selectedVariant == nil)
        #expect(store.selectedTargetLabel == nil)
    }

    @Test func searchResultsUseTheCatalogQuery() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        let store = await makeLoadedStore(cache: cache)

        store.searchText = "cafe"
        #expect(store.searchResults.map(\.name) == ["Café Audio"])

        store.searchText = ""
        #expect(store.searchResults.count == 3)
    }

    @Test func clearPreviewResetsState() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        let store = await makeLoadedStore(cache: cache)

        store.clearPreview()

        #expect(store.previewProfile == nil)
        #expect(store.previewState == .idle)
    }
}
