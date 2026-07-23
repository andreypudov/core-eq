import Combine
import Foundation

/// Holds the built-in profiles, the active selection, and the current working
/// band values (the active profile plus any slider tweaks). Persists the
/// selection and tweaks through `SettingsStore` and restores them on launch.
@MainActor
final class ProfileManager: ObservableObject {
    @Published private(set) var profiles: [EQProfile]
    @Published private(set) var activeProfileName: String
    @Published private(set) var currentBands: [EQBand]

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings

        let profiles = BuiltInProfiles.all
        self.profiles = profiles

        let savedName = settings.activeProfileName
        let active = profiles.first { $0.name == savedName }
            ?? profiles.first { $0.name == BuiltInProfiles.defaultProfileName }
            ?? profiles[0]
        self.activeProfileName = active.name

        var bands = active.bands
        if let customGains = settings.customGains, customGains.count == bands.count {
            for i in bands.indices {
                bands[i].gain = customGains[i].clamped(to: BuiltInProfiles.gainRange)
            }
        }
        self.currentBands = bands
    }

    func listProfiles() -> [EQProfile] {
        profiles
    }

    func getActiveProfile() -> EQProfile {
        profiles.first { $0.name == activeProfileName } ?? profiles[0]
    }

    /// Selecting a profile discards any custom slider tweaks and applies the
    /// profile's band values immediately.
    func setActiveProfile(name: String) {
        guard let profile = profiles.first(where: { $0.name == name }) else { return }
        activeProfileName = profile.name
        currentBands = profile.bands
        settings.activeProfileName = profile.name
        settings.customGains = nil
    }

    func setGain(_ gain: Double, forBandAt index: Int) {
        guard currentBands.indices.contains(index) else { return }
        currentBands[index].gain = gain.clamped(to: BuiltInProfiles.gainRange)
        settings.customGains = currentBands.map(\.gain)
    }

    /// Restores a single band to the active profile's original value
    /// (Lightroom-style double-click reset).
    func resetBand(at index: Int) {
        let profileBands = getActiveProfile().bands
        guard currentBands.indices.contains(index), profileBands.indices.contains(index) else { return }
        currentBands[index].gain = profileBands[index].gain
        settings.customGains = isModified ? currentBands.map(\.gain) : nil
    }

    /// Restores the active profile's original band values.
    func resetToActiveProfile() {
        currentBands = getActiveProfile().bands
        settings.customGains = nil
    }

    var isModified: Bool {
        currentBands != getActiveProfile().bands
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
