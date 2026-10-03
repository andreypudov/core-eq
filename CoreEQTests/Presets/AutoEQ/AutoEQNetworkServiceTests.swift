import Foundation
import Testing

/// Serialized because the stub protocol's handler and request log are process
/// global; these tests must not interleave.
@Suite(.serialized)
struct AutoEQNetworkServiceTests {
    private func makeService(cache: URL) -> AutoEQNetworkService {
        AutoEQNetworkService(session: .autoEQStubbed(), cacheDirectory: cache)
    }

    private static func catalogHandler() -> StubHandler {
        { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/entries":
                return (httpResponse(url: url), AutoEQTestFixtures.entriesData)
            case "/targets":
                return (httpResponse(url: url), AutoEQTestFixtures.targetsData)
            default:
                throw URLError(.badURL)
            }
        }
    }

    @Test func loadsCatalogAndWritesCache() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        StubURLProtocol.setHandler(Self.catalogHandler())
        let service = makeService(cache: cache)

        let catalog = try await service.loadCatalog()

        #expect(
            catalog.models.map(\.name) == [
                "Alpha Headphones", "Café Audio", "Zeta Headphones",
            ])
        #expect(catalog.targets.count == 3)
        let manager = FileManager.default
        #expect(manager.fileExists(atPath: cache.appendingPathComponent("entries.json").path))
        #expect(manager.fileExists(atPath: cache.appendingPathComponent("targets.json").path))
        // The documented User-Agent goes out on every request.
        #expect(
            StubURLProtocol.requests.allSatisfy {
                $0.value(forHTTPHeaderField: "User-Agent") == "CoreEQ/1.0"
            })
    }

    @Test func secondLoadIsServedFromFreshCache() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        StubURLProtocol.setHandler(Self.catalogHandler())
        let service = makeService(cache: cache)
        _ = try await service.loadCatalog()

        // A failing handler: if the fresh cache is used, no request is made.
        StubURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
        let second = try await service.loadCatalog()

        #expect(second.models.count == 3)
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func networkErrorWithNoCacheThrowsOffline() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        StubURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
        let service = makeService(cache: cache)

        do {
            _ = try await service.loadCatalog()
            Issue.record("expected loadCatalog to throw")
        } catch {
            #expect(error as? AutoEQError == .offline)
        }
    }

    @Test func networkErrorWithStaleCacheReturnsStaleCatalog() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        AutoEQTestFixtures.writeCache(
            into: cache, modified: Date().addingTimeInterval(-8 * 24 * 60 * 60))
        StubURLProtocol.setHandler { _ in throw URLError(.notConnectedToInternet) }
        let service = makeService(cache: cache)

        let catalog = try await service.loadCatalog()

        #expect(catalog.models.count == 3)
    }

    @Test func equalizeReturnsComputedProfile() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        StubURLProtocol.setHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return (httpResponse(url: url), Data(AutoEQTestFixtures.equalizeJSON.utf8))
        }
        let service = makeService(cache: cache)
        let variant = AutoEQVariant(
            source: "oratory1990", rig: "GRAS 43AG-7", form: "over-ear")

        let profile = try await service.equalize(
            model: "Alpha Headphones", variant: variant, targetLabel: "Harman over-ear 2013")

        #expect(profile.preamp == -6.0)
        #expect(profile.filters.count == 2)
        #expect(profile.filters[0].type == "PEAKING")
        #expect(profile.filters[0].fc == 105.0)
        #expect(profile.filters[1].type == "LOW_SHELF")
        #expect(StubURLProtocol.requests.first?.httpMethod == "POST")
    }

    @Test func equalizeNon200ThrowsHTTPStatus() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        StubURLProtocol.setHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return (httpResponse(url: url, status: 422), Data())
        }
        let service = makeService(cache: cache)
        let variant = AutoEQVariant(
            source: "oratory1990", rig: "GRAS 43AG-7", form: "over-ear")

        do {
            _ = try await service.equalize(
                model: "Alpha Headphones", variant: variant, targetLabel: "Harman over-ear 2013")
            Issue.record("expected equalize to throw")
        } catch {
            #expect(error as? AutoEQError == .httpStatus(422))
        }
    }

    @Test func equalizeWithNilRigThrowsUnsupportedVariant() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        StubURLProtocol.setHandler { _ in throw URLError(.badURL) }
        let service = makeService(cache: cache)
        let variant = AutoEQVariant(source: "crinacle", rig: nil, form: "in-ear")

        do {
            _ = try await service.equalize(
                model: "Alpha Headphones", variant: variant, targetLabel: "Harman in-ear 2019")
            Issue.record("expected equalize to throw")
        } catch {
            #expect(error as? AutoEQError == .unsupportedVariant)
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func fetchesPrecomputedText() async throws {
        let cache = AutoEQTestFixtures.makeCacheDirectory()
        defer { AutoEQTestFixtures.remove(cache) }
        let text = "Preamp: -1.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1.0 dB Q 1.00\n"
        StubURLProtocol.setHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return (httpResponse(url: url), Data(text.utf8))
        }
        let service = makeService(cache: cache)

        let fetched = try await service.fetchPrecomputedParametricEQ(
            model: "Zeta Headphones", source: "oratory1990", form: "over-ear")

        #expect(fetched == text)
    }

    @Test func precomputedURLPercentEncodesSpaces() throws {
        let url = try #require(
            AutoEQNetworkService.precomputedParametricEQURL(
                model: "Sennheiser HD 600", source: "oratory1990", form: "over-ear"))
        #expect(
            url.absoluteString
                == "https://cdn.jsdelivr.net/gh/jaakkopasanen/AutoEq@master/results/oratory1990/"
                + "over-ear/Sennheiser%20HD%20600/Sennheiser%20HD%20600%20ParametricEQ.txt")
    }
}
