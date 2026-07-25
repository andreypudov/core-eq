import Combine
import Foundation

/// Holds the built-in profiles, the active selection, and the current working
/// band values (the active profile plus any slider tweaks). Persists the
/// selection and tweaks through `SettingsStore` and restores them on launch.
@MainActor
final class ProfileManager: ObservableObject {
    /// The three menu-bar Quick EQ tone positions. See `QuickTone`.
    struct ToneControls: Equatable {
        var bass: Double = 0
        var mid: Double = 0
        var treble: Double = 0

        var isNeutral: Bool { self == ToneControls() }
    }

    @Published private(set) var profiles: [EQProfile]
    @Published private(set) var activeProfileName: String
    @Published private(set) var currentBands: [EQBand]

    /// Tone positions dialed in from the menu-bar Quick EQ, layered on top of
    /// the active profile. Kept separate from `currentBands` so the popover
    /// sliders can restore their positions; `currentBands` remains the single
    /// source of truth the engine renders.
    @Published private(set) var tone = ToneControls()

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

        var restoredTone = ToneControls()
        if let saved = settings.tone, saved.count == 3 {
            restoredTone = ToneControls(
                bass: saved[0].clamped(to: QuickTone.range),
                mid: saved[1].clamped(to: QuickTone.range),
                treble: saved[2].clamped(to: QuickTone.range)
            )
        }
        self.tone = restoredTone

        var bands = active.bands
        if !restoredTone.isNeutral {
            // Tone positions take precedence: derive the bands from them so the
            // popover and engine agree on launch.
            let offsets = QuickTone.offsets(bass: restoredTone.bass, mid: restoredTone.mid, treble: restoredTone.treble)
            for i in bands.indices {
                bands[i].gain = (active.bands[i].gain + offsets[i]).clamped(to: BuiltInProfiles.gainRange)
            }
        } else if let customGains = settings.customGains, customGains.count == bands.count {
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

    /// Selecting a profile discards any custom slider tweaks and re-centres the
    /// Quick EQ tone controls, applying the profile's band values immediately.
    func setActiveProfile(name: String) {
        guard let profile = profiles.first(where: { $0.name == name }) else { return }
        activeProfileName = profile.name
        tone = ToneControls()
        currentBands = profile.bands
        settings.activeProfileName = profile.name
        settings.customGains = nil
        settings.tone = nil
    }

    /// Updates one or more Quick EQ tone positions and re-derives the band
    /// gains as `activeProfile + tone offsets`, replacing any per-band tweaks.
    func setTone(bass: Double? = nil, mid: Double? = nil, treble: Double? = nil) {
        if let bass { tone.bass = bass.clamped(to: QuickTone.range) }
        if let mid { tone.mid = mid.clamped(to: QuickTone.range) }
        if let treble { tone.treble = treble.clamped(to: QuickTone.range) }

        let profileBands = getActiveProfile().bands
        let offsets = QuickTone.offsets(bass: tone.bass, mid: tone.mid, treble: tone.treble)
        var bands = profileBands
        for i in bands.indices {
            bands[i].gain = (profileBands[i].gain + offsets[i]).clamped(to: BuiltInProfiles.gainRange)
        }
        currentBands = bands
        settings.tone = tone.isNeutral ? nil : [tone.bass, tone.mid, tone.treble]
        settings.customGains = tone.isNeutral ? nil : currentBands.map(\.gain)
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

    /// Restores the active profile's original band values and re-centres the
    /// Quick EQ tone controls.
    func resetToActiveProfile() {
        tone = ToneControls()
        currentBands = getActiveProfile().bands
        settings.customGains = nil
        settings.tone = nil
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
