import Combine
import Foundation

/// Holds the built-in profiles, any presets the user created, the active
/// selection, and the current working band values (the active profile plus any
/// slider tweaks). Persists the selection, the user presets, and the tweaks
/// through `SettingsStore` and restores them on launch.
@MainActor
final class ProfileManager: ObservableObject {
    /// The three menu-bar Quick EQ tone positions. See `QuickTone`.
    struct ToneControls: Equatable {
        var bass: Double = 0
        var mid: Double = 0
        var treble: Double = 0

        var isNeutral: Bool { self == ToneControls() }
    }

    /// The profiles shipped with CoreEQ. Read-only.
    let builtInProfiles: [EQProfile]

    /// Presets the user created. Renameable, editable, and deletable.
    @Published private(set) var userProfiles: [EQProfile]

    @Published private(set) var activeProfileName: String
    @Published private(set) var currentBands: [EQBand]

    /// Tone positions dialed in from the menu-bar Quick EQ, layered on top of
    /// the active profile. Kept separate from `currentBands` so the popover
    /// sliders can restore their positions; `currentBands` remains the single
    /// source of truth the engine renders.
    @Published private(set) var tone = ToneControls()

    /// The preset the sidebar should be showing as an editable text field, or
    /// nil when no rename is in progress.
    ///
    /// Lives here rather than in the sidebar's own `@State` because a preset can
    /// be created from outside the sidebar — the window toolbar's + button — and
    /// a freshly created preset should always land with its name selected. The
    /// sidebar is the only reader; everyone else just asks for a rename.
    @Published var profileAwaitingRename: String?

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings

        let builtIns = BuiltInProfiles.all
        self.builtInProfiles = builtIns

        // Drop any stored preset whose name collides with a built-in or with an
        // earlier entry, so `profiles` always has unique, stable identifiers.
        var seen = Set(builtIns.map(\.name))
        let userProfiles = settings.userProfiles
            .filter { seen.insert($0.name).inserted }
            .map(Self.alignedToBandLadder)
        self.userProfiles = userProfiles

        let profiles = builtIns + userProfiles
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

    /// Built-in profiles first, then the user's own — the order the sidebar and
    /// the menu bar present them in.
    var profiles: [EQProfile] {
        builtInProfiles + userProfiles
    }

    func listProfiles() -> [EQProfile] {
        profiles
    }

    func getActiveProfile() -> EQProfile {
        profiles.first { $0.name == activeProfileName } ?? builtInProfiles[0]
    }

    func profile(named name: String) -> EQProfile? {
        profiles.first { $0.name == name }
    }

    /// Selecting a profile discards any custom slider tweaks and re-centres the
    /// Quick EQ tone controls, applying the profile's band values immediately.
    func setActiveProfile(name: String) {
        guard let profile = profile(named: name) else { return }
        activeProfileName = profile.name
        tone = ToneControls()
        currentBands = profile.bands
        settings.activeProfileName = profile.name
        settings.customGains = nil
        settings.tone = nil
    }

    // MARK: - User presets

    /// Creates a user preset from `bands` (the working values by default) and
    /// makes it active. Returns the name it was actually stored under, which is
    /// `name` made unique against the existing profiles.
    @discardableResult
    func addProfile(named name: String = "New Preset", bands: [EQBand]? = nil) -> String {
        let profile = EQProfile(name: uniqueName(from: name), bands: bands ?? currentBands)
        userProfiles.append(profile)
        persistUserProfiles()
        setActiveProfile(name: profile.name)
        profileAwaitingRename = profile.name
        return profile.name
    }

    /// Rewrites a stored profile's center frequencies and Q onto the current
    /// band ladder, keeping its gains.
    ///
    /// Every profile shares one fixed ladder by design, so a profile saved under
    /// an earlier ladder would otherwise keep stale frequencies and label its
    /// slider differently from every other preset. Profiles whose band count no
    /// longer matches are left untouched rather than silently reshaped.
    private static func alignedToBandLadder(_ profile: EQProfile) -> EQProfile {
        let ladder = BuiltInProfiles.frequencies
        guard profile.bands.count == ladder.count else { return profile }
        var aligned = profile
        for index in aligned.bands.indices {
            aligned.bands[index].frequency = ladder[index]
            aligned.bands[index].q = BuiltInProfiles.defaultQ
        }
        return aligned
    }

    /// Asks the sidebar to put `name` into inline editing. Built-in profiles
    /// can't be renamed, so requesting one is a no-op.
    func beginRename(of name: String) {
        guard canEditProfile(named: name) else { return }
        profileAwaitingRename = name
    }

    /// Copies any profile — built-in or user — into a new user preset named
    /// "<name> copy", and makes it active.
    @discardableResult
    func duplicateProfile(named name: String) -> String? {
        guard let source = profile(named: name) else { return nil }
        return addProfile(named: "\(source.name) copy", bands: source.bands)
    }

    /// Renames a user preset. Built-in profiles and empty names are ignored, and
    /// a name that collides with an existing profile gets a numeric suffix.
    @discardableResult
    func renameProfile(named name: String, to newName: String) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = userProfiles.firstIndex(where: { $0.name == name }),
              !trimmed.isEmpty,
              trimmed != name
        else { return nil }

        let unique = uniqueName(from: trimmed)
        userProfiles[index].name = unique
        persistUserProfiles()
        if activeProfileName == name {
            activeProfileName = unique
            settings.activeProfileName = unique
        }
        return unique
    }

    /// Deletes a user preset. If it was active, the selection falls back to the
    /// neighbouring preset, or to Flat when no user presets remain.
    func deleteProfile(named name: String) {
        guard let index = userProfiles.firstIndex(where: { $0.name == name }) else { return }
        userProfiles.remove(at: index)
        persistUserProfiles()
        if profileAwaitingRename == name { profileAwaitingRename = nil }

        guard activeProfileName == name else { return }
        let fallback = userProfiles[safe: index]?.name
            ?? userProfiles[safe: index - 1]?.name
            ?? BuiltInProfiles.defaultProfileName
        setActiveProfile(name: fallback)
    }

    /// Writes the working band values into the active user preset, so the
    /// current sound becomes the preset's saved state.
    func saveChangesToActiveProfile() {
        guard let index = userProfiles.firstIndex(where: { $0.name == activeProfileName }) else { return }
        userProfiles[index].bands = currentBands
        persistUserProfiles()
        tone = ToneControls()
        settings.customGains = nil
        settings.tone = nil
    }

    func canEditProfile(named name: String) -> Bool {
        userProfiles.contains { $0.name == name }
    }

    // MARK: - Band editing

    func setGain(_ gain: Double, forBandAt index: Int) {
        guard currentBands.indices.contains(index) else { return }
        currentBands[index].gain = gain.clamped(to: BuiltInProfiles.gainRange)
        settings.customGains = currentBands.map(\.gain)
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

    // MARK: - Private

    private func persistUserProfiles() {
        settings.userProfiles = userProfiles
    }

    /// `name` if no profile uses it, otherwise "name 2", "name 3", …
    private func uniqueName(from name: String) -> String {
        let taken = Set(profiles.map(\.name))
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) \(suffix)") {
            suffix += 1
        }
        return "\(name) \(suffix)"
    }
}
