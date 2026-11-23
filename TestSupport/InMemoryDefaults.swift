import Foundation

/// A `UserDefaults` that lives only in memory.
///
/// A per-test `UserDefaults(suiteName:)` is the obvious isolation, but it leaks:
/// cfprefsd persists each written suite to `~/Library/Preferences`
/// asynchronously, and can flush it back to disk *after*
/// `removePersistentDomain(forName:)` and even after the backing file has been
/// deleted. Cleanup therefore cannot be made reliable — one empty plist per
/// written suite is recreated every run. Keeping the store entirely in memory
/// means there is never a plist to clean up.
final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }

    override func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    override func array(forKey defaultName: String) -> [Any]? {
        storage[defaultName] as? [Any]
    }

    override func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            storage[defaultName] = value
        } else {
            storage.removeValue(forKey: defaultName)
        }
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}
