import Foundation

/// Thin `UserDefaults` wrapper for the persisted app state: active profile,
/// EQ enabled flag, and any custom band gain tweaks made in the main window.
final class SettingsStore {
    private enum Key {
        static let activeProfileName = "activeProfileName"
        static let isEnabled = "isEQEnabled"
        static let customGains = "customBandGains"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var activeProfileName: String? {
        get { defaults.string(forKey: Key.activeProfileName) }
        set { defaults.set(newValue, forKey: Key.activeProfileName) }
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Key.isEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.isEnabled) }
    }

    /// Gains the user has dialed in on top of the active profile, or nil when
    /// the profile is unmodified.
    var customGains: [Double]? {
        get { defaults.array(forKey: Key.customGains) as? [Double] }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.customGains)
            } else {
                defaults.removeObject(forKey: Key.customGains)
            }
        }
    }
}
