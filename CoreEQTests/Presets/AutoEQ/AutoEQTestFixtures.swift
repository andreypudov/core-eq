import Foundation

enum AutoEQTestFixtures {
    static let revision = String(repeating: "a", count: 40)
    static let nextRevision = String(repeating: "b", count: 40)
    static let index = """
        # Index
        - [Zeta Headphones](./oratory1990/over-ear/Zeta%20Headphones) by oratory1990
        - [Alpha Headphones](./oratory1990/GRAS%2043AG-7%20over-ear/Alpha%20Headphones) by oratory1990 on GRAS 43AG-7
        - [Alpha Headphones](./Rtings/HMS%20II.3%20over-ear/Alpha%20Headphones) by Rtings on HMS II.3
        - [Alpha Headphones](./crinacle/711%20in-ear/Alpha%20Headphones) by crinacle on 711
        - [Café Audio](./Super%20Review/in-ear/Caf%C3%A9%20Audio) by Super Review
        - [Excluded](./Crinacle/711%20in-ear/Excluded) by Crinacle
        """
    static var indexData: Data { Data(index.utf8) }
    static let profileText = """
        Preamp: -6.0 dB
        Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.41
        Filter 2: ON LSC Fc 105 Hz Gain 5.0 dB Q 0.70
        """

    static func makeCacheDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreeq-autoeq-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func writeCache(
        into directory: URL, revision: String = revision, index: Data = indexData,
        checkedAt: Date = Date(), version: Int = 1
    ) throws {
        let value = Snapshot(
            version: version, revision: revision, checkedAt: checkedAt, index: index)
        try JSONEncoder().encode(value).write(
            to: directory.appendingPathComponent("catalog-v1.json"), options: .atomic)
    }

    static func catalogHandler(revision: String = revision, index: Data = indexData) -> StubHandler
    {
        { request in
            let url = request.url!
            if url == AutoEQNetworkService.revisionURL {
                return (httpResponse(url: url), Data("{\"sha\":\"\(revision)\"}".utf8))
            }
            if url.path.hasSuffix("/INDEX.md") {
                return (
                    httpResponse(url: url, headers: ["Content-Length": "\(index.count)"]), index
                )
            }
            if url.path.hasSuffix(" ParametricEQ.txt") {
                return (httpResponse(url: url), Data(profileText.utf8))
            }
            throw URLError(.badURL)
        }
    }

    private struct Snapshot: Codable {
        let version: Int
        let revision: String
        let checkedAt: Date
        let index: Data
    }
}

func httpResponse(
    url: URL, status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"]
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}
