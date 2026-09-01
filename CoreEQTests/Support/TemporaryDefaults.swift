import Foundation

/// A `UserDefaults` suite that lives no longer than the test that made it.
///
/// A suite per test is the only way these tests can run in any order without
/// reading each other's state, but the obvious cleanup is not enough:
/// `removePersistentDomain(forName:)` empties the domain and leaves the backing
/// plist in `~/Library/Preferences`. One file per test, kept forever, is a leak
/// nothing ever reports — so the file has to go too.
struct TemporaryDefaults {
    let suiteName: String
    let values: UserDefaults

    init?() {
        let name = "coreeq.tests.\(UUID().uuidString)"
        guard let values = UserDefaults(suiteName: name) else { return nil }
        suiteName = name
        self.values = values
    }

    func remove() {
        values.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeSuite(named: suiteName)
        try? FileManager.default.removeItem(at: Self.plistURL(for: suiteName))
    }

    private static func plistURL(for suiteName: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent(suiteName)
            .appendingPathExtension("plist")
    }
}
