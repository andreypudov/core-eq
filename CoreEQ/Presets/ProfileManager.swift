import Combine
import Foundation

/// Holds the built-in profiles, any presets the user created, the active
/// selection, and the working chain (the active profile plus any edits since).
/// Persists the selection, the user presets, and the working chain through
/// `SettingsStore` and restores them on launch.
///
/// The chain is kept normalised: the first `BuiltInProfiles.bandCount` entries
/// are the ladder filters in slot order, and everything after them is a free
/// filter. The slider strip is therefore always exactly eleven controls that
/// index straight into the array, no matter what the user has added.
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

    /// The complete chain being rendered: eleven ladder filters followed by any
    /// free filters. The single source of truth for the engine and the graph.
    @Published private(set) var currentFilters: [EQFilter]

    /// Output trim in dB, applied after the chain. Part of the working state
    /// alongside `currentFilters`, and saved into the preset with it.
    @Published private(set) var currentPreamp: Double

    /// Tone positions dialed in from the menu-bar Quick EQ, layered on top of
    /// the active profile. Kept separate from `currentFilters` so the popover
    /// sliders can restore their positions.
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
            .map { EQProfile(name: $0.name, filters: Self.normalized($0.filters)) }
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

        if !restoredTone.isNeutral {
            // Tone positions take precedence: derive the chain from them so the
            // popover and engine agree on launch.
            self.currentFilters = Self.applyingTone(restoredTone, to: active.filters)
        } else if let stored = settings.workingFilters {
            self.currentFilters = Self.normalized(stored)
        } else if let legacy = settings.legacyCustomGains, legacy.count == BuiltInProfiles.bandCount {
            // Slider tweaks saved by CoreEQ 1.x, carried over once so an update
            // doesn't silently discard what the user was listening to.
            var chain = active.filters
            for slot in 0..<BuiltInProfiles.bandCount {
                chain[slot].gain = legacy[slot].clamped(to: BuiltInProfiles.gainRange)
            }
            self.currentFilters = chain
            settings.workingFilters = chain
            settings.legacyCustomGains = nil
        } else {
            self.currentFilters = active.filters
        }

        self.currentPreamp = (settings.workingPreamp ?? active.preamp)
            .clamped(to: BuiltInProfiles.preampRange)
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

    // MARK: - Reading the chain

    /// The eleven ladder filters, in slot order. What the slider strip draws.
    var bandFilters: [EQFilter] {
        Array(currentFilters.prefix(BuiltInProfiles.bandCount))
    }

    /// Everything the user added by hand. What the filter list draws.
    var freeFilters: [EQFilter] {
        Array(currentFilters.dropFirst(BuiltInProfiles.bandCount))
    }

    var canAddFilter: Bool {
        freeFilters.count < BuiltInProfiles.maxFreeFilters
    }

    /// Total gain of the whole chain at `frequency` — what the curve reads
    /// there, and what the tick on each slider marks.
    ///
    /// This is a readout and never a control: a slider always sets its own
    /// filter's gain, so nothing here can move a knob the user did not touch.
    func totalGain(at frequency: Double, sampleRate: Double) -> Double {
        currentFilters.reduce(currentPreamp) { total, filter in
            total + Biquad(filter: filter, sampleRate: sampleRate)
                .magnitudeDB(at: frequency, sampleRate: sampleRate)
        }
    }

    // MARK: - Presets

    /// Selecting a profile replaces the entire chain — free filters included —
    /// and re-centres the Quick EQ tone controls. A preset is the complete
    /// sound, so `Flat` is flat rather than flat plus whatever was left over.
    func setActiveProfile(name: String) {
        guard let profile = profile(named: name) else { return }
        activeProfileName = profile.name
        tone = ToneControls()
        currentFilters = profile.filters
        currentPreamp = profile.preamp
        settings.activeProfileName = profile.name
        settings.workingFilters = nil
        settings.workingPreamp = nil
        settings.tone = nil
    }

    /// Creates a user preset from `filters` (the working chain by default) and
    /// makes it active. Returns the name it was actually stored under, which is
    /// `name` made unique against the existing profiles.
    @discardableResult
    func addProfile(
        named name: String = "New Preset",
        filters: [EQFilter]? = nil,
        preamp: Double? = nil
    ) -> String {
        let profile = EQProfile(
            name: uniqueName(from: name),
            filters: filters ?? currentFilters,
            preamp: preamp ?? currentPreamp
        )
        userProfiles.append(profile)
        persistUserProfiles()
        setActiveProfile(name: profile.name)
        profileAwaitingRename = profile.name
        return profile.name
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
        return addProfile(named: "\(source.name) copy", filters: source.filters, preamp: source.preamp)
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

    /// Writes the working chain into the active user preset, so the current
    /// sound — bands and free filters together — becomes the preset's saved
    /// state.
    func saveChangesToActiveProfile() {
        guard let index = userProfiles.firstIndex(where: { $0.name == activeProfileName }) else { return }
        userProfiles[index].filters = currentFilters
        userProfiles[index].preamp = currentPreamp
        persistUserProfiles()
        tone = ToneControls()
        settings.workingFilters = nil
        settings.workingPreamp = nil
        settings.tone = nil
    }

    func canEditProfile(named name: String) -> Bool {
        userProfiles.contains { $0.name == name }
    }

    // MARK: - Band editing

    func setGain(_ gain: Double, forBandAt slot: Int) {
        guard slot < BuiltInProfiles.bandCount, currentFilters.indices.contains(slot) else { return }
        currentFilters[slot].gain = gain.clamped(to: BuiltInProfiles.gainRange)
        persistWorkingChain()
    }

    /// Restores a single band to the active profile's original value
    /// (Lightroom-style double-click reset).
    func resetBand(at slot: Int) {
        let profileBands = getActiveProfile().bandFilters
        guard slot < BuiltInProfiles.bandCount,
              currentFilters.indices.contains(slot),
              profileBands.indices.contains(slot) else { return }
        currentFilters[slot].gain = profileBands[slot].gain
        persistWorkingChain()
    }

    /// Switches the whole ladder on or off, for hearing what it contributes on
    /// its own.
    func setBandsEnabled(_ isEnabled: Bool) {
        for slot in 0..<min(BuiltInProfiles.bandCount, currentFilters.count) {
            currentFilters[slot].isEnabled = isEnabled
        }
        persistWorkingChain()
    }

    var areBandsEnabled: Bool {
        bandFilters.contains(where: \.isEnabled)
    }

    // MARK: - Free filters

    /// Adds a filter and returns its id. Refuses past `maxFreeFilters`, which
    /// keeps both the window and the render budget bounded.
    @discardableResult
    func addFilter(
        kind: EQFilter.Kind = .bell,
        frequency: Double = 1_000,
        gain: Double = 0,
        q: Double = 1.0
    ) -> UUID? {
        guard canAddFilter else { return nil }
        let filter = EQFilter(
            kind: kind,
            frequency: frequency.clamped(to: BuiltInProfiles.filterFrequencyRange),
            gain: gain.clamped(to: BuiltInProfiles.gainRange),
            q: q.clamped(to: BuiltInProfiles.filterQRange)
        )
        currentFilters.append(filter)
        persistWorkingChain()
        return filter.id
    }

    func removeFilter(id: UUID) {
        guard let index = indexOfFreeFilter(id: id) else { return }
        currentFilters.remove(at: index)
        persistWorkingChain()
    }

    func setFilterKind(_ kind: EQFilter.Kind, id: UUID) {
        updateFreeFilter(id: id) { $0.kind = kind }
    }

    func setFilterFrequency(_ frequency: Double, id: UUID) {
        updateFreeFilter(id: id) {
            $0.frequency = frequency.clamped(to: BuiltInProfiles.filterFrequencyRange)
        }
    }

    func setFilterGain(_ gain: Double, id: UUID) {
        updateFreeFilter(id: id) { $0.gain = gain.clamped(to: BuiltInProfiles.gainRange) }
    }

    func setFilterQ(_ q: Double, id: UUID) {
        updateFreeFilter(id: id) { $0.q = q.clamped(to: BuiltInProfiles.filterQRange) }
    }

    func setFilterEnabled(_ isEnabled: Bool, id: UUID) {
        updateFreeFilter(id: id) { $0.isEnabled = isEnabled }
    }

    /// Double-click on a filter's node: back to 0 dB, matching what a
    /// double-click does to a band. Delete lives in the context menu, because an
    /// accidental reset is recoverable in a way an accidental delete is not.
    func resetFilter(id: UUID) {
        updateFreeFilter(id: id) { $0.gain = 0 }
    }

    /// Switches every free filter on or off, for hearing the ladder alone.
    func setFreeFiltersEnabled(_ isEnabled: Bool) {
        for index in BuiltInProfiles.bandCount..<currentFilters.count {
            currentFilters[index].isEnabled = isEnabled
        }
        persistWorkingChain()
    }

    var areFreeFiltersEnabled: Bool {
        freeFilters.contains(where: \.isEnabled)
    }

    /// Lifts a band out of the slider strip and into the filter list, where its
    /// frequency and Q become editable.
    ///
    /// The filter keeps its kind, frequency, gain, and Q, so its coefficients —
    /// and the sound — are unchanged. Its slot stays in the strip at 0 dB, which
    /// is identity, so the ladder keeps its eleven sliders and the chain sums to
    /// exactly what it did before. This is a move, not a conversion; the reverse
    /// is not offered, because fitting free filters back onto a fixed ladder
    /// would be an approximation.
    @discardableResult
    func editBandAsFilter(slot: Int) -> UUID? {
        guard canAddFilter,
              slot < BuiltInProfiles.bandCount,
              currentFilters.indices.contains(slot) else { return nil }
        let lifted = currentFilters[slot].unbound()
        currentFilters[slot].gain = 0
        currentFilters[slot].isEnabled = true
        currentFilters.append(lifted)
        persistWorkingChain()
        return lifted.id
    }

    // MARK: - Quick EQ tone

    /// Updates one or more Quick EQ tone positions and re-derives the band gains
    /// as `activeProfile + tone offsets`, replacing any per-band tweaks. Free
    /// filters are left alone: the tone controls are a shortcut into the ladder,
    /// not into the whole chain.
    func setTone(bass: Double? = nil, mid: Double? = nil, treble: Double? = nil) {
        if let bass { tone.bass = bass.clamped(to: QuickTone.range) }
        if let mid { tone.mid = mid.clamped(to: QuickTone.range) }
        if let treble { tone.treble = treble.clamped(to: QuickTone.range) }

        let profileBands = getActiveProfile().bandFilters
        let offsets = QuickTone.offsets(bass: tone.bass, mid: tone.mid, treble: tone.treble)
        for slot in 0..<min(BuiltInProfiles.bandCount, currentFilters.count) {
            let base = profileBands[safe: slot]?.gain ?? 0
            currentFilters[slot].gain = (base + offsets[slot]).clamped(to: BuiltInProfiles.gainRange)
        }
        settings.tone = tone.isNeutral ? nil : [tone.bass, tone.mid, tone.treble]
        persistWorkingChain()
    }

    /// Restores the active profile's chain and re-centres the Quick EQ tone
    /// controls.
    func resetToActiveProfile() {
        tone = ToneControls()
        let profile = getActiveProfile()
        currentFilters = profile.filters
        currentPreamp = profile.preamp
        settings.workingFilters = nil
        settings.workingPreamp = nil
        settings.tone = nil
    }

    // MARK: - Output trim

    func setPreamp(_ dB: Double) {
        currentPreamp = dB.clamped(to: BuiltInProfiles.preampRange)
        settings.workingPreamp = isModified ? currentPreamp : nil
    }

    var isModified: Bool {
        currentFilters != getActiveProfile().filters || currentPreamp != getActiveProfile().preamp
    }

    // MARK: - Private

    private func indexOfFreeFilter(id: UUID) -> Int? {
        guard let index = currentFilters.firstIndex(where: { $0.id == id }),
              index >= BuiltInProfiles.bandCount else { return nil }
        return index
    }

    private func updateFreeFilter(id: UUID, _ change: (inout EQFilter) -> Void) {
        guard let index = indexOfFreeFilter(id: id) else { return }
        change(&currentFilters[index])
        persistWorkingChain()
    }

    private func persistWorkingChain() {
        let modified = isModified
        settings.workingFilters = modified ? currentFilters : nil
        settings.workingPreamp = modified ? currentPreamp : nil
    }

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

    /// Rewrites any chain into the invariant shape: exactly `bandCount` ladder
    /// filters in slot order, then the free filters.
    ///
    /// Every band's frequency and Q come from the ladder rather than from the
    /// stored value, so a preset saved under an earlier ladder can't keep stale
    /// centre frequencies and label its slider differently from every other
    /// preset. Free filters are capped so a hand-edited defaults entry cannot
    /// push the chain past the render budget.
    static func normalized(_ filters: [EQFilter]) -> [EQFilter] {
        var bands = BuiltInProfiles.emptyBandChain()
        var free: [EQFilter] = []

        for filter in filters {
            if let slot = filter.band, bands.indices.contains(slot) {
                bands[slot].gain = filter.gain.clamped(to: BuiltInProfiles.gainRange)
                bands[slot].isEnabled = filter.isEnabled
            } else if free.count < BuiltInProfiles.maxFreeFilters {
                var loose = filter.unbound()
                loose.frequency = loose.frequency.clamped(to: BuiltInProfiles.filterFrequencyRange)
                loose.gain = loose.gain.clamped(to: BuiltInProfiles.gainRange)
                loose.q = loose.q.clamped(to: BuiltInProfiles.filterQRange)
                free.append(loose)
            }
        }
        return bands + free
    }

    /// The chain `profileFilters` becomes with the tone controls applied to its
    /// ladder. Free filters pass through untouched.
    private static func applyingTone(_ tone: ToneControls, to profileFilters: [EQFilter]) -> [EQFilter] {
        var chain = profileFilters
        let offsets = QuickTone.offsets(bass: tone.bass, mid: tone.mid, treble: tone.treble)
        for slot in 0..<min(BuiltInProfiles.bandCount, chain.count) {
            chain[slot].gain = (chain[slot].gain + offsets[slot]).clamped(to: BuiltInProfiles.gainRange)
        }
        return chain
    }
}
