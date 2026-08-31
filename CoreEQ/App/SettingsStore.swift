import Foundation

/// Thin `UserDefaults` wrapper for the persisted app state: active profile,
/// EQ enabled flag, user-created presets, and the working chain — the active
/// preset plus whatever the user has changed since selecting it.
///
/// Main-actor isolated. `UserDefaults` is thread-safe on its own, but this type
/// caches on top of it, and every owner — the profile manager, the engine, the
/// app delegate — is already on the main actor. Stating that here keeps the
/// cache correct by construction rather than by convention.
@MainActor
final class SettingsStore {
    private enum Key {
        static let activeProfileName = "activeProfileName"
        static let isEnabled = "isEQEnabled"
        static let customGains = "customBandGains"
        static let workingFilters = "workingFilters"
        static let workingPreamp = "workingPreamp"
        static let tone = "quickToneControls"
        static let userProfiles = "userProfiles"
        static let deviceStates = "deviceStates"
        static let lastOutputDeviceUID = "lastOutputDeviceUID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Persistent UID of the output the app was last filing state under.
    ///
    /// Core Audio does not always have an answer at launch — a device still
    /// waking, or none connected at all — and without this the app files that
    /// session under the no-device slot, where the state is invisible to every
    /// real device afterwards.
    var lastOutputDeviceUID: String? {
        get { defaults.string(forKey: Key.lastOutputDeviceUID) }
        set { defaults.set(newValue, forKey: Key.lastOutputDeviceUID) }
    }

    var activeProfileName: String? {
        get { defaults.string(forKey: Key.activeProfileName) }
        set { defaults.set(newValue, forKey: Key.activeProfileName) }
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Key.isEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.isEnabled) }
    }

    /// Band gains dialed in on top of the active profile by CoreEQ 1.x.
    ///
    /// Read once at launch, migrated into `workingFilters`, then set to nil so
    /// the two can't disagree. Nothing in the app writes a value here — that is
    /// a fact about the callers, not something this setter enforces.
    var legacyCustomGains: [Double]? {
        get { defaults.array(forKey: Key.customGains) as? [Double] }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.customGains)
            } else {
                defaults.removeObject(forKey: Key.customGains)
            }
        }
    }

    /// The chain the user is actually hearing — the active preset plus any
    /// edits since — or nil when it still matches the preset.
    ///
    /// Stored whole rather than as a gain array, because free filters carry a
    /// kind, frequency, and Q that a bare list of gains cannot express.
    var workingFilters: [EQFilter]? {
        get {
            guard let data = defaults.data(forKey: Key.workingFilters) else { return nil }
            return try? JSONDecoder().decode([EQFilter].self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.workingFilters)
            } else {
                defaults.removeObject(forKey: Key.workingFilters)
            }
        }
    }

    /// Output trim the user has dialed in on top of the active preset, or nil
    /// when it still matches.
    var workingPreamp: Double? {
        get { defaults.object(forKey: Key.workingPreamp) as? Double }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.workingPreamp)
            } else {
                defaults.removeObject(forKey: Key.workingPreamp)
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

    /// What was playing on each output device, keyed by its persistent UID.
    ///
    /// Replaces the single active-preset / working-chain / trim / tone keys,
    /// which are now read once at launch to seed the current device's slot and
    /// never written again.
    ///
    /// Held in memory and written through, because this is the one setting on an
    /// interaction path: every step of a slider drag files the working chain
    /// under the current device, and each of those went through a full decode of
    /// every device's state purely to put one key back. Reading is now free and
    /// only the encode remains.
    var deviceStates: [String: DeviceEQState] {
        get {
            if let cachedDeviceStates { return cachedDeviceStates }
            let stored =
                defaults.data(forKey: Key.deviceStates)
                .flatMap { try? JSONDecoder().decode([String: DeviceEQState].self, from: $0) }
                ?? [:]
            cachedDeviceStates = stored
            return stored
        }
        set {
            cachedDeviceStates = newValue
            if newValue.isEmpty {
                defaults.removeObject(forKey: Key.deviceStates)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.deviceStates)
            }
        }
    }

    /// Mirror of `deviceStates`, populated on first read. Valid because a store
    /// is the only writer of its own defaults key.
    private var cachedDeviceStates: [String: DeviceEQState]?

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
