import Foundation
import Testing

extension AutoEQIntegrationTests {
    @MainActor
    struct Store {
        private func loadedStore(_ cache: URL) async throws -> AutoEQStore {
            try AutoEQTestFixtures.writeCache(into: cache)
            let store = AutoEQStore(
                service: AutoEQNetworkService(session: .autoEQStubbed(), cacheDirectory: cache))
            await store.loadCatalog()
            return store
        }

        @Test func loadsCacheAndSelectsPublishedCorrectionWithoutCustomTargets() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            StubURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
            let store = try await loadedStore(cache)
            #expect(store.catalogState == .loaded)
            #expect(store.models.count == 3)
            #expect(store.catalogRevision == AutoEQTestFixtures.revision)
            store.selectModel(named: "Alpha Headphones")
            #expect(store.selectedVariant?.source == "oratory1990")
            #expect(store.selectedTargetLabel == AutoEQCatalogParser.defaultTargetLabel)
            #expect(!store.supportsCustomTargets)
            #expect(
                !StubURLProtocol.requests.contains {
                    $0.url?.path.hasSuffix(" ParametricEQ.txt") == true
                })
            store.selectVariant(store.availableVariants[1])
            #expect(store.selectedVariant?.source == "Rtings")
            store.selectTarget(label: "Unsupported custom target")
            #expect(store.selectedTargetLabel == AutoEQCatalogParser.defaultTargetLabel)
        }

        @Test func customTargetCanBeComputedAndCachedForACompatibleSource() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let target = AutoEQTarget(
                label: "Alternative",
                compatible: [
                    .init(source: "oratory1990", rig: "GRAS 43AG-7", form: "over-ear")
                ], recommended: [], fr: .init(frequency: [20, 1000, 20000], raw: [2, 0, -2]))
            let targetData = try JSONEncoder().encode([target])
            StubURLProtocol.setHandler { request in
                let url = request.url!
                if url.path.hasSuffix("targets.json") {
                    return (httpResponse(url: url), targetData)
                }
                if url.path.hasSuffix(".csv") {
                    return (
                        httpResponse(url: url), Data("frequency,raw\n20,0\n1000,0\n20000,0".utf8)
                    )
                }
                return try AutoEQTestFixtures.catalogHandler()(request)
            }
            let store = try await loadedStore(cache)
            store.selectModel(named: "Alpha Headphones")
            #expect(store.supportsCustomTargets)
            #expect(store.availableTargets.map(\.label).contains("Alternative"))
            store.selectTarget(label: "Alternative")
            let profile = try #require(await store.loadSelectedProfile())
            #expect(profile.name == "Alpha Headphones · Alternative")
            #expect(profile.freeFilters.count == AutoEQLocalSolver.filterCount)
            #expect(await store.loadSelectedProfile() == profile)
            let suite = "coreeq-local-import-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let manager = ProfileManager(settings: SettingsStore(defaults: defaults))
            manager.beginAudition(profile)
            let savedName = try #require(manager.saveAuditionAsPreset(named: profile.name))
            #expect(
                manager.profile(named: savedName)?.freeFilters.count
                    == AutoEQLocalSolver.filterCount)
            let csvRequests = StubURLProtocol.requests.filter {
                $0.url?.path.hasSuffix(".csv") == true
            }
            #expect(csvRequests.count == 1)
            let service = AutoEQNetworkService(session: .autoEQStubbed(), cacheDirectory: cache)
            #expect(
                try await service.computeProfile(
                    model: "Alpha Headphones", variant: store.selectedVariant!, target: target,
                    revision: AutoEQTestFixtures.revision
                ).filters.count == AutoEQLocalSolver.filterCount)
            #expect(
                try await service.computeProfile(
                    model: "Alpha Headphones", variant: store.selectedVariant!, target: target,
                    revision: AutoEQTestFixtures.nextRevision
                ).filters.count
                    == AutoEQLocalSolver.filterCount)
            let updatedCSVRequests = StubURLProtocol.requests.filter {
                $0.url?.path.hasSuffix(".csv") == true
            }
            #expect(updatedCSVRequests.count == 2)
            let computedFiles = try FileManager.default.contentsOfDirectory(
                at: cache.appendingPathComponent("computed-v\(AutoEQLocalSolver.version)"),
                includingPropertiesForKeys: nil)
            #expect(computedFiles.count == 2)
        }

        @Test func unriggedMeasurementPreviewsAndCanBeSavedAsAPreset() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            let store = try await loadedStore(cache)
            store.selectModel(named: "Zeta Headphones")
            let profile = try #require(await store.loadSelectedProfile())
            #expect(store.previewState == .ready)
            #expect(profile.name == "Zeta Headphones")
            #expect(profile.preamp == -6)
            #expect(!profile.isBuiltIn)
            #expect(!profile.autoGain)
            // The candidates behind the preview are published, and a
            // representable correction flags no adjustment.
            #expect(store.previewCandidates != nil)
            #expect(!store.previewWouldAdjust)
            let suite = "coreeq-autoeq-import-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let manager = ProfileManager(settings: SettingsStore(defaults: defaults))
            manager.beginAudition(profile)
            #expect(manager.isAuditioning)
            let savedName = try #require(manager.saveAuditionAsPreset(named: profile.name))
            #expect(manager.profile(named: savedName)?.name == profile.name)
            #expect(!manager.isAuditioning)
        }

        @Test func publishedCorrectionThatWouldAdjustPreviewsAndFlagsIt() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let store = try await loadedStore(cache)
            let adjusting = "Preamp: -6 dB\nFilter 1: ON PK Fc 125 Hz Gain -20 dB Q 1.41\n"
            StubURLProtocol.setHandler { request in
                let url = request.url!
                if url.path.hasSuffix(" ParametricEQ.txt") {
                    return (httpResponse(url: url), Data(adjusting.utf8))
                }
                return try AutoEQTestFixtures.catalogHandler()(request)
            }
            store.selectModel(named: "Alpha Headphones")
            let profile = try #require(await store.loadSelectedProfile())

            // It previews rather than failing, and the flag reflects the
            // disclosure that saving would change the correction.
            #expect(store.previewState == .ready)
            #expect(store.previewWouldAdjust)
            #expect(store.previewCandidates?.disclosure.clippableCount == 1)
            // The graph and audition hear the exact (kept) version.
            #expect(profile.freeFilters.first?.gain == -20)

            store.cancelPreview()
            #expect(store.previewCandidates == nil)
            #expect(!store.previewWouldAdjust)
            #expect(store.previewProfile == nil)
        }

        @Test func searchAndInvalidSelectionsRemainSafe() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let store = try await loadedStore(cache)
            store.searchText = "cafe"
            #expect(store.searchResults.map(\.name) == ["Café Audio"])
            store.searchText = "alpha"
            #expect(store.searchResults.map(\.name) == ["Alpha Headphones"])
            store.selectModel(named: "Nonexistent")
            #expect(store.selectedModelName == nil)
            store.selectVariant(AutoEQVariant(source: "crinacle", form: "in-ear"))
            #expect(store.selectedVariant == nil)
            #expect(await store.loadSelectedProfile() == nil)
            #expect(store.previewState == .idle)
            #expect(store.previewProfile == nil)
        }

        @Test func browserOpenResetIsSeparateFromCatalogReload() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let store = try await loadedStore(cache)
            store.selectModel(named: "Alpha Headphones")
            store.searchText = "alpha"
            await store.loadCatalog(forceRefresh: true)
            #expect(store.selectedModelName == "Alpha Headphones")
            #expect(store.searchText == "alpha")
            store.resetSelectionForBrowserOpen()
            #expect(store.selectedModelName == nil)
            #expect(store.selectedVariant == nil)
            #expect(store.selectedTargetLabel == nil)
            #expect(store.searchText.isEmpty)
            #expect(store.searchResults.count == 3)
            #expect(store.previewState == .idle)
        }

        @Test func selectionChangeDuringDownloadCannotPublishAnOldPreview() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let store = try await loadedStore(cache)
            store.selectModel(named: "Alpha Headphones")
            // Run the selection change before the protocol releases the response.
            StubURLProtocol.setHandler { request in
                DispatchQueue.main.sync { store.selectModel(named: "Zeta Headphones") }
                return (httpResponse(url: request.url!), Data(AutoEQTestFixtures.profileText.utf8))
            }
            #expect(await store.loadSelectedProfile() == nil)
            #expect(store.previewProfile == nil)
        }

        @Test func closingDuringCatalogLoadCancelsAndAllowsReopening() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let store = AutoEQStore(
                service: AutoEQNetworkService(session: .autoEQStubbed(), cacheDirectory: cache))
            StubURLProtocol.setHandler { request in
                DispatchQueue.main.sync { store.cancelCatalogLoad() }
                return (
                    httpResponse(url: request.url!),
                    Data("{\"sha\":\"\(AutoEQTestFixtures.revision)\"}".utf8)
                )
            }
            await store.loadCatalog()
            #expect(store.catalogState == .idle)
            #expect(store.models.isEmpty)
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            await store.loadCatalog()
            #expect(store.catalogState == .loaded)
        }

        @Test func updateFailureShowsStaleCatalogAndPreviewFailuresAllowRetry() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let store = try await loadedStore(cache)
            StubURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
            await store.loadCatalog(forceRefresh: true)
            #expect(store.catalogIsStale)
            store.selectModel(named: "Alpha Headphones")
            #expect(await store.loadSelectedProfile() == nil)
            if case .failed = store.previewState {
            } else {
                Issue.record("Expected preview failure")
            }
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            #expect(await store.loadSelectedProfile() != nil)
            store.cancelPreview()
            #expect(store.previewProfile == nil)
            #expect(store.previewState == .idle)
        }
    }
}
