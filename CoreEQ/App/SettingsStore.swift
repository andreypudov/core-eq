import Foundation

/// Thin `UserDefaults` wrapper for the persisted app state: active profile,
/// EQ enabled flag, user-created presets, and any custom band gain tweaks made
/// in the main window.
final class SettingsStore {
    private enum Key {
        static let activeProfileName = "activeProfileName"
        static let isEnabled = "isEQEnabled"
        static let customGains = "customBandGains"
        static let tone = "quickToneControls"
        static let userProfiles = "userProfiles"
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

    /// Menu-bar Quick EQ tone positions as `[bass, mid, treble]`, or nil when
    /// all three are centred.
    var tone: [Double]? {
        get { defaults.array(forKey: Key.tone) as? [Double] }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.tone)
            } else {
                defaults.removeObject(forKey: Key.tone)
            }
        }
    }

    /// Presets the user created in the main window, stored as JSON. Empty when
    /// the user hasn't made any. Decoding failures fall back to an empty list
    /// rather than throwing, so a corrupt entry can never block launch.
    var userProfiles: [EQProfile] {
        get {
            guard let data = defaults.data(forKey: Key.userProfiles) else { return [] }
            return (try? JSONDecoder().decode([EQProfile].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Key.userProfiles)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.userProfiles)
            }
        }
    }
}
