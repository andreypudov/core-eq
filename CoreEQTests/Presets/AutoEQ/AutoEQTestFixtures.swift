import Foundation

/// Inline AutoEQ payloads and small helpers for the AutoEQ tests. The shapes
/// mirror the live endpoints at a scale the tests can reason about.
enum AutoEQTestFixtures {
    /// Three models: one with a single `nil`-rig variant, one with two variants,
    /// and one whose name carries a diacritic.
    static let entriesJSON = """
        {
          "Zeta Headphones": [
            {"source": "oratory1990", "rig": null, "form": "over-ear"}
          ],
          "Alpha Headphones": [
            {"source": "oratory1990", "rig": "GRAS 43AG-7", "form": "over-ear"},
            {"source": "crinacle", "rig": null, "form": "in-ear"}
          ],
          "Café Audio": [
            {"source": "crinacle", "rig": "IEC60318-4", "form": "in-ear"}
          ]
        }
        """

    /// Over-ear targets that recommend and merely tolerate `Alpha Headphones`'
    /// GRAS variant, plus an in-ear target for its crinacle variant.
    static let targetsJSON = """
        [
          {
            "label": "Harman over-ear 2018",
            "compatible": [
              {"source": "oratory1990", "rig": "GRAS 43AG-7", "form": "over-ear"}
            ],
            "recommended": [],
            "bassBoost": {"gain": 0}
          },
          {
            "label": "Harman in-ear 2019",
            "compatible": [],
            "recommended": [
              {"source": "crinacle", "rig": null, "form": "in-ear"}
            ],
            "bassBoost": {}
          },
          {
            "label": "Harman over-ear 2013",
            "compatible": [
              {"source": "oratory1990", "rig": "GRAS 43AG-7", "form": "over-ear"}
            ],
            "recommended": [
              {"source": "oratory1990", "rig": "GRAS 43AG-7", "form": "over-ear"}
            ],
            "bassBoost": {}
          }
        ]
        """

    static let equalizeJSON = """
        {
          "parametric_eq": {
            "preamp": -6.0,
            "filters": [
              {"type": "PEAKING", "fc": 105.0, "q": 1.41, "gain": 3.0},
              {"type": "LOW_SHELF", "fc": 105.0, "q": 0.70, "gain": 5.0}
            ]
          },
          "fr": {}
        }
        """

    static var entriesData: Data { Data(entriesJSON.utf8) }
    static var targetsData: Data { Data(targetsJSON.utf8) }

    /// A unique, empty cache directory removed when `remove` is called.
    static func makeCacheDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreeq-autoeq-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes both cache files, optionally dating them into the past.
    static func writeCache(
        into directory: URL, entries: Data = entriesData, targets: Data = targetsData,
        modified: Date? = nil
    ) {
        let entriesURL = directory.appendingPathComponent("entries.json")
        let targetsURL = directory.appendingPathComponent("targets.json")
        try? entries.write(to: entriesURL, options: .atomic)
        try? targets.write(to: targetsURL, options: .atomic)
        guard let modified else { return }
        for url in [entriesURL, targetsURL] {
            try? FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
        }
    }
}

/// A canned HTTP response for `StubURLProtocol`.
func httpResponse(
    url: URL, status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"]
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}
