import CryptoKit
import Foundation

enum AutoEQCatalogProgress: Sendable, Equatable {
    case checkingRevision
    case downloading(received: Int, total: Int?)
    case preparing

    var fraction: Double? {
        guard case .downloading(let received, let total) = self, let total, total > 0 else {
            return nil
        }
        return min(Double(received) / Double(total), 1)
    }

    var message: String {
        switch self {
        case .checkingRevision: return "Checking for AutoEq updates…"
        case .downloading: return "Downloading the AutoEq catalog…"
        case .preparing: return "Preparing the AutoEq catalog…"
        }
    }
}

/// Downloads published AutoEq results from an immutable GitHub revision.
/// Construction performs no I/O; the browser starts the first download.
actor AutoEQNetworkService {
    static let revisionURL = URL(
        string: "https://api.github.com/repos/jaakkopasanen/AutoEq/commits/master")!
    static let cacheMaxAge: TimeInterval = 7 * 24 * 60 * 60
    static let cacheVersion = 1

    private let session: URLSession
    private let cacheDirectory: URL
    private var snapshot: CatalogSnapshot?

    static var userAgent: String {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "CoreEQ/\(version ?? "development")"
    }

    init(session: URLSession = .shared, cacheDirectory: URL? = nil) {
        self.session = session
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
    }

    /// Check weekly or on an explicit refresh. Failed updates retain the last
    /// complete snapshot; cancellation never becomes an offline result.
    func loadCatalog(
        forceRefresh: Bool = false,
        progress: @Sendable (AutoEQCatalogProgress) async -> Void = { _ in }
    ) async throws -> AutoEQCatalog {
        try Task.checkCancellation()
        let cached = snapshot ?? readSnapshot()
        if !forceRefresh, let cached, cached.isFresh {
            snapshot = cached
            return try cached.catalog()
        }
        do {
            await progress(.checkingRevision)
            let data = try await fetchData(from: Self.revisionURL)
            let revision = try JSONDecoder().decode(Revision.self, from: data).sha
            guard Self.isRevision(revision) else { throw AutoEQError.malformedData }
            let index: Data
            if let cached, cached.revision == revision {
                index = cached.index
            } else {
                index = try await downloadIndex(revision: revision, progress: progress)
            }
            await progress(.preparing)
            let updated = CatalogSnapshot(
                version: Self.cacheVersion, revision: revision, checkedAt: Date(), index: index)
            let catalog = try updated.catalog()
            try Task.checkCancellation()
            snapshot = updated
            writeSnapshot(updated)
            return catalog
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw error
            }
            if let cached {
                snapshot = cached
                return try cached.catalog(isStale: true)
            }
            if error is AutoEQError { throw error }
            if error is DecodingError { throw AutoEQError.malformedData }
            throw AutoEQError.offline
        }
    }

    /// Profiles are cached by commit and exact result path. Updating the
    /// catalog cannot accidentally reuse a correction from an older revision.
    func fetchPrecomputedParametricEQ(
        model: String, variant: AutoEQVariant, revision: String
    ) async throws -> String {
        try Task.checkCancellation()
        guard Self.isRevision(revision), let path = variant.resultPath,
            let parts = AutoEQCatalogParser.resultComponents(path),
            parts[0] == variant.source, parts[2] == model
        else { throw AutoEQError.unsupportedVariant }
        let relativePath = path + "/" + model + " ParametricEQ.txt"
        let digest = SHA256.hash(data: Data(relativePath.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = cacheDirectory.appendingPathComponent("profiles").appendingPathComponent(
            revision)
        let file = directory.appendingPathComponent(digest + ".txt")
        if let data = try? Data(contentsOf: file),
            let text = try? Self.profileText(data, model: model)
        {
            return text
        }
        let data = try await fetchData(from: Self.resultURL(revision: revision, path: relativePath))
        let text = try Self.profileText(data, model: model)
        try Task.checkCancellation()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return text
    }

    func loadTargets(revision: String) async throws -> [AutoEQTarget] {
        guard Self.isRevision(revision) else { throw AutoEQError.malformedData }
        let data = try await cachedInput(revision: revision, path: "webapp/data/targets.json")
        let targets = try JSONDecoder().decode([AutoEQTarget].self, from: data)
        return targets.filter { $0.fr?.isValid == true }
    }

    func computeProfile(
        model: String, variant: AutoEQVariant, target: AutoEQTarget,
        revision: String
    ) async throws -> AutoEQEqualizedProfile {
        guard Self.isRevision(revision), let path = variant.resultPath,
            let parts = AutoEQCatalogParser.resultComponents(path), parts[0] == variant.source,
            parts[2] == model,
            target.supports(source: variant.source, rig: variant.rig, form: variant.form)
        else { throw AutoEQError.unsupportedVariant }
        let data = try await cachedInput(
            revision: revision, path: "results/" + path + "/" + model + ".csv")
        let curve = try AutoEQCurve.csv(data)
        var identity = Data("\(revision):\(path)".utf8)
        identity.append(data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        identity.append(try encoder.encode(target))
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let directory = cacheDirectory.appendingPathComponent(
            "computed-v\(AutoEQLocalSolver.version)")
        let file = directory.appendingPathComponent(digest + ".json")
        if let cached = try? Data(contentsOf: file),
            let profile = try? JSONDecoder().decode(AutoEQEqualizedProfile.self, from: cached),
            profile.preamp.isFinite, profile.filters.count == AutoEQLocalSolver.filterCount,
            profile.filters.allSatisfy({ $0.fc.isFinite && $0.q.isFinite && $0.gain.isFinite })
        {
            try Task.checkCancellation()
            return profile
        }
        let worker = Task.detached(priority: .userInitiated) {
            try AutoEQLocalSolver.compute(measurement: curve, target: target)
        }
        let profile = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(profile).write(to: file, options: .atomic)
        return profile
    }

    private func cachedInput(revision: String, path: String) async throws -> Data {
        try Task.checkCancellation()
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = cacheDirectory.appendingPathComponent("inputs").appendingPathComponent(
            revision)
        let file = directory.appendingPathComponent(digest)
        if let data = try? Data(contentsOf: file) { return data }
        let data = try await fetchData(from: Self.repositoryURL(revision: revision, path: path))
        if path.hasSuffix(".csv") {
            _ = try AutoEQCurve.csv(data)
        } else {
            let targets = try JSONDecoder().decode([AutoEQTarget].self, from: data)
            guard targets.contains(where: { $0.fr?.isValid == true }) else {
                throw AutoEQError.malformedData
            }
        }
        try Task.checkCancellation()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    static func isRevision(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy { "0123456789abcdef".contains($0) }
    }

    static func resultURL(revision: String, path: String) -> URL {
        repositoryURL(revision: revision, path: "results/" + path)
    }

    private static func repositoryURL(revision: String, path: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = path.components(separatedBy: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "/")
        return URL(
            string:
                "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/\(revision)/\(encoded)"
        )!
    }

    private static func profileText(_ data: Data, model: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutoEQError.malformedData
        }
        // A 200 response containing an error page must not poison offline
        // previews. This validates shape, not range: an out-of-range value is
        // disclosed on every load, so only text that carries no gain-bearing
        // filter at all is rejected here.
        _ = try ParametricEQParser.parse(text: text, defaultName: model)
        let sourceFilters = text.components(separatedBy: .newlines).compactMap {
            ParametricEQParser.parseFilterLine(from: $0.trimmingCharacters(in: .whitespaces))
        }
        guard sourceFilters.contains(where: { $0.kind.usesGain }) else {
            throw AutoEQError.malformedData
        }
        return text
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AutoEQError.invalidResponse }
        guard http.statusCode == 200 else { throw AutoEQError.httpStatus(http.statusCode) }
    }

    private func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: request(for: url))
        try Task.checkCancellation()
        try validate(response)
        return data
    }

    private func downloadIndex(
        revision: String, progress: @Sendable (AutoEQCatalogProgress) async -> Void
    ) async throws -> Data {
        let url = Self.resultURL(revision: revision, path: "INDEX.md")
        let (bytes, response) = try await session.bytes(for: request(for: url))
        try validate(response)
        let total = response.expectedContentLength > 0 ? Int(response.expectedContentLength) : nil
        var data = Data()
        await progress(.downloading(received: 0, total: total))
        for try await byte in bytes {
            data.append(byte)
            if data.count.isMultiple(of: 32_768) {
                try Task.checkCancellation()
                await progress(.downloading(received: data.count, total: total))
            }
        }
        try Task.checkCancellation()
        await progress(.downloading(received: data.count, total: total))
        return data
    }

    private var snapshotURL: URL { cacheDirectory.appendingPathComponent("catalog-v1.json") }

    private func readSnapshot() -> CatalogSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL),
            let cached = try? JSONDecoder().decode(CatalogSnapshot.self, from: data),
            cached.version == Self.cacheVersion, Self.isRevision(cached.revision),
            (try? cached.catalog()) != nil
        else { return nil }
        return cached
    }

    private func writeSnapshot(_ value: CatalogSnapshot) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: snapshotURL, options: .atomic)
    }

    private static func defaultCacheDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "CoreEQ")
            .appendingPathComponent("AutoEQ")
    }
}

private struct Revision: Decodable { let sha: String }

private struct CatalogSnapshot: Codable {
    let version: Int
    let revision: String
    let checkedAt: Date
    let index: Data

    var isFresh: Bool {
        let age = Date().timeIntervalSince(checkedAt)
        return age >= 0 && age < AutoEQNetworkService.cacheMaxAge
    }

    func catalog(isStale: Bool = false) throws -> AutoEQCatalog {
        try AutoEQCatalogParser.parseIndex(index, revision: revision, isStale: isStale)
    }
}
