import Foundation

/// Fetches the AutoEQ catalog and computes corrections, caching the catalog on
/// disk so browsing works offline.
///
/// An actor because the cache and the catalogue it guards are shared across the
/// UI's tasks; the network and file work are the reason the methods are async
/// at all. There is no other concurrency in the app.
actor AutoEQNetworkService {
    static let entriesURL = URL(string: "https://autoeq.app/entries")!
    static let targetsURL = URL(string: "https://autoeq.app/targets")!
    static let equalizeURL = URL(string: "https://autoeq.app/equalize")!

    /// How long a cached catalog is trusted before a refresh is attempted.
    private static let cacheMaxAge: TimeInterval = 7 * 24 * 60 * 60

    private let session: URLSession
    private let cacheDirectory: URL

    private var entriesFileURL: URL { cacheDirectory.appendingPathComponent("entries.json") }
    private var targetsFileURL: URL { cacheDirectory.appendingPathComponent("targets.json") }

    /// - Parameters:
    ///   - session: the session to fetch with; injectable so tests can stub the
    ///     network with a `URLProtocol`.
    ///   - cacheDirectory: where the catalog is cached. Defaults to
    ///     `Caches/<bundle id>/AutoEQ`.
    init(session: URLSession = .shared, cacheDirectory: URL? = nil) {
        self.session = session
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
    }

    // MARK: - Catalog

    /// Returns the catalog, from cache when it is recent enough.
    ///
    /// When the network fails, a stale cache is better than nothing and is
    /// returned instead of an error; only with no cache at all does this throw.
    func loadCatalog(forceRefresh: Bool = false) async throws -> AutoEQCatalog {
        if !forceRefresh, let fresh = cachedCatalogIfFresh() {
            return fresh
        }

        do {
            return try await fetchAndCacheCatalog()
        } catch {
            if let stale = readCachedCatalog() {
                return stale
            }
            throw AutoEQError.offline
        }
    }

    // MARK: - Equalize

    /// Computes AutoEQ's parametric correction for one variant toward one target.
    ///
    /// - Throws: `AutoEQError.unsupportedVariant` for a variant with no rig,
    ///   which `/equalize` cannot process. Callers should fall back to
    ///   `fetchPrecomputedParametricEQ`.
    func equalize(
        model: String, variant: AutoEQVariant, targetLabel: String, bassBoostGain: Double = 0
    ) async throws -> AutoEQEqualizedProfile {
        guard variant.rig != nil else { throw AutoEQError.unsupportedVariant }

        let body = EqualizeRequest(
            name: model,
            source: variant.source,
            rig: variant.rig,
            target: targetLabel,
            bassBoostGain: bassBoostGain,
            parametricEQ: true,
            parametricEQConfig: "8_PEAKING_WITH_SHELVES",
            response: EmptyResponse())

        var request = URLRequest(url: Self.equalizeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CoreEQ/1.0", forHTTPHeaderField: "User-Agent")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw AutoEQError.malformedData
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AutoEQError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw AutoEQError.httpStatus(http.statusCode)
        }

        let decoded: EqualizeResponse
        do {
            decoded = try JSONDecoder().decode(EqualizeResponse.self, from: data)
        } catch {
            throw AutoEQError.malformedData
        }
        return AutoEQEqualizedProfile(
            filters: decoded.parametricEQ.filters.map {
                AutoEQEqualizedFilter(type: $0.type, fc: $0.fc, q: $0.q, gain: $0.gain)
            },
            preamp: decoded.parametricEQ.preamp)
    }

    /// Fetches AutoEQ's pre-computed parametric EQ text, the fallback for
    /// variants that `/equalize` rejects.
    func fetchPrecomputedParametricEQ(
        model: String, source: String, form: String
    ) async throws
        -> String
    {
        guard let url = Self.precomputedParametricEQURL(model: model, source: source, form: form)
        else {
            throw AutoEQError.invalidResponse
        }
        let data = try await fetchData(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutoEQError.malformedData
        }
        return text
    }

    // MARK: - URL construction

    /// The jsDelivr URL for a pre-computed parametric EQ file. Exposed for
    /// tests; each path component is percent-encoded so `&` survives and spaces
    /// become `%20`.
    static func precomputedParametricEQURL(model: String, source: String, form: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        let filename = "\(model) ParametricEQ.txt"
        let path =
            "https://cdn.jsdelivr.net/gh/jaakkopasanen/AutoEq@master/results/"
            + "\(encode(source))/\(encode(form))/\(encode(model))/\(encode(filename))"
        return URL(string: path)
    }

    // MARK: - Networking

    /// Fetches data from a URL, validating HTTP 200.
    ///
    /// `nonisolated` so the two catalog requests can run concurrently.
    private nonisolated func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("CoreEQ/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AutoEQError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw AutoEQError.httpStatus(http.statusCode)
        }
        return data
    }

    private func fetchAndCacheCatalog() async throws -> AutoEQCatalog {
        async let entriesData = fetchData(from: Self.entriesURL)
        async let targetsData = fetchData(from: Self.targetsURL)
        let (entries, targets) = try await (entriesData, targetsData)

        let models = try AutoEQCatalogParser.parseEntries(entries)
        let parsedTargets = try AutoEQCatalogParser.parseTargets(targets)
        guard !models.isEmpty else { throw AutoEQError.emptyCatalog }

        writeCache(entries: entries, targets: targets)
        return AutoEQCatalog(models: models, targets: parsedTargets)
    }

    // MARK: - Cache

    private func cachedCatalogIfFresh() -> AutoEQCatalog? {
        guard isFresh(entriesFileURL), isFresh(targetsFileURL) else { return nil }
        return readCachedCatalog()
    }

    private func isFresh(_ url: URL) -> Bool {
        guard
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        else {
            return false
        }
        return Date().timeIntervalSince(modified) < Self.cacheMaxAge
    }

    /// Reads and parses both cache files, or `nil` if either is missing or
    /// damaged — a broken cache is simply a cache miss.
    private func readCachedCatalog() -> AutoEQCatalog? {
        guard let entries = try? Data(contentsOf: entriesFileURL),
            let targets = try? Data(contentsOf: targetsFileURL),
            let models = try? AutoEQCatalogParser.parseEntries(entries),
            let parsedTargets = try? AutoEQCatalogParser.parseTargets(targets),
            !models.isEmpty
        else {
            return nil
        }
        return AutoEQCatalog(models: models, targets: parsedTargets)
    }

    /// Writes both files atomically. Failures are ignored on purpose: a cache
    /// that cannot be written is a performance problem, never a correctness one,
    /// and must not take the app down.
    private func writeCache(entries: Data, targets: Data) {
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        try? entries.write(to: entriesFileURL, options: .atomic)
        try? targets.write(to: targetsFileURL, options: .atomic)
    }

    private static func defaultCacheDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let identifier = Bundle.main.bundleIdentifier ?? "CoreEQ"
        return base.appendingPathComponent(identifier).appendingPathComponent("AutoEQ")
    }
}

// MARK: - Wire types

/// The `/equalize` request body. Field names match the endpoint, which is why
/// they differ from Swift's naming.
private struct EqualizeRequest: Encodable {
    let name: String
    let source: String
    let rig: String?
    let target: String
    let bassBoostGain: Double
    let parametricEQ: Bool
    let parametricEQConfig: String
    let response: EmptyResponse

    enum CodingKeys: String, CodingKey {
        case name, source, rig, target, response
        case bassBoostGain = "bass_boost_gain"
        case parametricEQ = "parametric_eq"
        case parametricEQConfig = "parametric_eq_config"
    }
}

/// Serializes to `{}`, the `response` field `/equalize` expects.
private struct EmptyResponse: Codable {}

private struct EqualizeResponse: Decodable {
    let parametricEQ: EqualizedBody

    enum CodingKeys: String, CodingKey {
        case parametricEQ = "parametric_eq"
    }
}

private struct EqualizedBody: Decodable {
    let preamp: Double
    let filters: [FilterBody]
}

private struct FilterBody: Decodable {
    let type: String
    let fc: Double
    let q: Double
    let gain: Double
}
