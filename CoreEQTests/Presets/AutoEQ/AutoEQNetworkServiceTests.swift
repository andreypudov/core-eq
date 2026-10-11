import Foundation
import Testing

extension AutoEQIntegrationTests {
    struct NetworkService {
        private func service(_ cache: URL) -> AutoEQNetworkService {
            AutoEQNetworkService(session: .autoEQStubbed(), cacheDirectory: cache)
        }

        @Test func doesNoWorkUntilRequestedThenPinsCatalogAndReportsProgress() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            let service = service(cache)
            #expect(StubURLProtocol.requests.isEmpty)
            let progress = ProgressLog()
            let catalog = try await service.loadCatalog { await progress.append($0) }
            #expect(catalog.models.count == 3)
            #expect(catalog.revision == AutoEQTestFixtures.revision)
            #expect(!catalog.isStale)
            #expect(StubURLProtocol.requests.count == 2)
            #expect(StubURLProtocol.requests.last?.url?.path.contains(catalog.revision) == true)
            #expect(
                StubURLProtocol.requests.allSatisfy {
                    $0.httpMethod == "GET" && $0.url?.host != "autoeq.app"
                        && $0.value(forHTTPHeaderField: "User-Agent")
                            == AutoEQNetworkService.userAgent
                })
            let events = await progress.events
            #expect(events.first == .checkingRevision)
            #expect(
                events.contains(
                    .downloading(
                        received: AutoEQTestFixtures.indexData.count,
                        total: AutoEQTestFixtures.indexData.count)))
            #expect(events.last == .preparing)
            #expect(
                FileManager.default.fileExists(
                    atPath: cache.appendingPathComponent("catalog-v1.json").path))
        }

        @Test func freshDiskCacheWorksAcrossServiceInstancesWithoutNetwork() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            _ = try await service(cache).loadCatalog()
            StubURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
            let catalog = try await service(cache).loadCatalog()
            #expect(catalog.models.count == 3)
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func staleCacheSurvivesOfflineRefreshAndIsMarkedStale() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            try AutoEQTestFixtures.writeCache(
                into: cache, checkedAt: Date().addingTimeInterval(-8 * 86_400))
            StubURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
            let catalog = try await service(cache).loadCatalog()
            #expect(catalog.isStale)
            #expect(catalog.revision == AutoEQTestFixtures.revision)
        }

        @Test func unchangedRevisionOnlyChecksTheRevision() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            try AutoEQTestFixtures.writeCache(into: cache)
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            let catalog = try await service(cache).loadCatalog(forceRefresh: true)
            #expect(!catalog.isStale)
            #expect(StubURLProtocol.requests.map(\.url) == [AutoEQNetworkService.revisionURL])
        }

        @Test func newRevisionUpdatesTheSnapshotAndPinsDownloads() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            try AutoEQTestFixtures.writeCache(into: cache)
            StubURLProtocol.setHandler(
                AutoEQTestFixtures.catalogHandler(revision: AutoEQTestFixtures.nextRevision))
            let catalog = try await service(cache).loadCatalog(forceRefresh: true)
            #expect(catalog.revision == AutoEQTestFixtures.nextRevision)
            #expect(StubURLProtocol.requests.last?.url?.path.contains(catalog.revision) == true)
            StubURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
            #expect(try await service(cache).loadCatalog().revision == catalog.revision)
        }

        @Test func failedIndexUpdateKeepsTheOldSnapshotAtomically() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            try AutoEQTestFixtures.writeCache(into: cache)
            StubURLProtocol.setHandler(
                AutoEQTestFixtures.catalogHandler(
                    revision: AutoEQTestFixtures.nextRevision, index: Data("broken".utf8)))
            let catalog = try await service(cache).loadCatalog(forceRefresh: true)
            #expect(catalog.revision == AutoEQTestFixtures.revision)
            #expect(catalog.isStale)
            #expect(try await service(cache).loadCatalog().revision == AutoEQTestFixtures.revision)
        }

        @Test func noCacheAndNoNetworkReportsOffline() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            StubURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
            await #expect(throws: AutoEQError.offline) {
                _ = try await service(cache).loadCatalog()
            }
        }

        @Test(arguments: [0, 2]) func incompatibleCacheVersionIsRefetched(version: Int) async throws
        {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            try AutoEQTestFixtures.writeCache(into: cache, version: version)
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            _ = try await service(cache).loadCatalog()
            #expect(StubURLProtocol.requests.count == 2)
        }

        @Test func corruptCacheAndLegacyCacheAreIgnored() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            try Data("{}".utf8).write(to: cache.appendingPathComponent("catalog-v1.json"))
            try Data("legacy backend entries".utf8).write(
                to: cache.appendingPathComponent("entries.json"))
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            #expect(try await service(cache).loadCatalog().models.count == 3)
            #expect(StubURLProtocol.requests.count == 2)
        }

        @Test func profilesDownloadOnDemandAndWorkOfflineAfterRestart() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            try AutoEQTestFixtures.writeCache(into: cache)
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            let service = service(cache)
            let catalog = try await service.loadCatalog()
            #expect(StubURLProtocol.requests.isEmpty)
            let variant = try #require(catalog.models.first?.variants.first)
            let text = try await service.fetchPrecomputedParametricEQ(
                model: "Alpha Headphones", variant: variant, revision: catalog.revision)
            #expect(text == AutoEQTestFixtures.profileText)
            #expect(StubURLProtocol.requests.count == 1)
            #expect(StubURLProtocol.requests.first?.url?.path.contains(catalog.revision) == true)
            StubURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
            #expect(
                try await self.service(cache).fetchPrecomputedParametricEQ(
                    model: "Alpha Headphones", variant: variant, revision: catalog.revision) == text
            )
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func profileCacheNeverCrossesRevisionBoundaries() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            let service = service(cache)
            let variant = AutoEQVariant(
                source: "oratory1990", form: "over-ear",
                resultPath: "oratory1990/over-ear/Alpha Headphones")
            _ = try await service.fetchPrecomputedParametricEQ(
                model: "Alpha Headphones", variant: variant, revision: AutoEQTestFixtures.revision)
            _ = try await service.fetchPrecomputedParametricEQ(
                model: "Alpha Headphones", variant: variant,
                revision: AutoEQTestFixtures.nextRevision)
            #expect(StubURLProtocol.requests.count == 2)
        }

        @Test func rejectsRestrictedSourcesAndUnsafePathsBeforeNetwork() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            StubURLProtocol.setHandler { _ in throw URLError(.badURL) }
            for path in [
                "crinacle/711 in-ear/Alpha", "Crinacle/over-ear/Alpha",
                "../over-ear/Alpha", "source/over-ear/../Alpha",
            ] {
                let variant = AutoEQVariant(
                    source: path.components(separatedBy: "/")[0],
                    form: "over-ear", resultPath: path)
                await #expect(throws: AutoEQError.unsupportedVariant) {
                    _ = try await service(cache).fetchPrecomputedParametricEQ(
                        model: "Alpha", variant: variant, revision: AutoEQTestFixtures.revision)
                }
            }
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func malformedProfileIsNotCachedAndCanBeRetried() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let variant = AutoEQVariant(
                source: "source", form: "over-ear", resultPath: "source/over-ear/Alpha")
            StubURLProtocol.setHandler { request in
                (httpResponse(url: request.url!), Data("<html>Error</html>".utf8))
            }
            do {
                _ = try await service(cache).fetchPrecomputedParametricEQ(
                    model: "Alpha", variant: variant, revision: AutoEQTestFixtures.revision)
                Issue.record("Malformed profile was accepted")
            } catch {}
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            _ = try await service(cache).fetchPrecomputedParametricEQ(
                model: "Alpha", variant: variant, revision: AutoEQTestFixtures.revision)
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test func outOfRangePrecomputedProfileIsCachedForLoadTimeDisclosure() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let variant = AutoEQVariant(
                source: "source", form: "over-ear", resultPath: "source/over-ear/Alpha")
            let adjusting = "Preamp: -6 dB\nFilter 1: ON PK Fc 125 Hz Gain -20 dB Q 1.41\n"
            StubURLProtocol.setHandler { request in
                (httpResponse(url: request.url!), Data(adjusting.utf8))
            }
            // Range is no longer a download-time rejection: the raw text is
            // cached, and the load discloses any adjustment.
            let text = try await service(cache).fetchPrecomputedParametricEQ(
                model: "Alpha", variant: variant, revision: AutoEQTestFixtures.revision)
            #expect(text == adjusting)
        }

        @Test(arguments: [0.0, 3.0])
        func precomputedGraphicBandCorrectionIsAccepted(gain: Double) async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let variant = AutoEQVariant(
                source: "source", form: "over-ear", resultPath: "source/over-ear/Alpha")
            let text = "Preamp: -3 dB\nFilter 1: ON PK Fc 125 Hz Gain \(gain) dB Q 1.41\n"
            StubURLProtocol.setHandler { request in
                (httpResponse(url: request.url!), Data(text.utf8))
            }
            let loaded = try await service(cache).fetchPrecomputedParametricEQ(
                model: "Alpha", variant: variant, revision: AutoEQTestFixtures.revision)
            #expect(loaded == text)
        }

        @Test func precomputedProfileWithoutAGainBearingFilterIsRejected() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            let variant = AutoEQVariant(
                source: "source", form: "over-ear", resultPath: "source/over-ear/Alpha")
            StubURLProtocol.setHandler { request in
                (httpResponse(url: request.url!), Data("Filter 1: ON HP Fc 20 Hz Q 0.71\n".utf8))
            }
            await #expect(throws: AutoEQError.malformedData) {
                _ = try await service(cache).fetchPrecomputedParametricEQ(
                    model: "Alpha", variant: variant, revision: AutoEQTestFixtures.revision)
            }
        }

        @Test func rateLimitPreservesCacheAndReportsHTTPStatusWithoutCache() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            StubURLProtocol.setHandler { request in
                (httpResponse(url: request.url!, status: 403), Data())
            }
            await #expect(throws: AutoEQError.httpStatus(403)) {
                _ = try await service(cache).loadCatalog()
            }
            try AutoEQTestFixtures.writeCache(into: cache)
            #expect(try await service(cache).loadCatalog(forceRefresh: true).isStale)
        }

        @Test func cancellationDoesNotReturnStaleDataOrPublishNewCache() async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            try AutoEQTestFixtures.writeCache(into: cache)
            StubURLProtocol.setHandler { _ in throw URLError(.cancelled) }
            await #expect(throws: URLError.self) {
                _ = try await service(cache).loadCatalog(forceRefresh: true)
            }
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler())
            let task = Task {
                try await service(cache).loadCatalog(forceRefresh: true) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }

        @Test func urlsEncodeReservedCharactersAndProgressHandlesUnknownLength() {
            let url = AutoEQNetworkService.resultURL(
                revision: AutoEQTestFixtures.revision,
                path: "Source Name/711 in-ear/A & B?#%/A & B?#% ParametricEQ.txt")
            #expect(url.query == nil && url.fragment == nil)
            #expect(url.absoluteString.contains("A%20%26%20B%3F%23%25"))
            #expect(AutoEQCatalogProgress.downloading(received: 10, total: nil).fraction == nil)
            #expect(AutoEQCatalogProgress.downloading(received: 50, total: 100).fraction == 0.5)
        }
    }
}

private actor ProgressLog {
    var events: [AutoEQCatalogProgress] = []
    func append(_ value: AutoEQCatalogProgress) { events.append(value) }
}
