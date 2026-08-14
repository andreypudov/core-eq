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

    /// Persistent UID of the output device whose state is currently loaded, or
    /// nil before one is known. Everything the user changes is written to this
    /// device's slot.
    private(set) var outputDeviceUID: String?

    init(settings: SettingsStore, outputDeviceUID: String? = nil) {
        self.settings = settings
        self.outputDeviceUID = outputDeviceUID

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
        let state = Self.migratedStateIfNeeded(settings: settings, deviceUID: outputDeviceUID)
            ?? settings.deviceStates[Self.slot(for: outputDeviceUID)]
            ?? DeviceEQState(profileName: BuiltInProfiles.defaultProfileName)

        let active = profiles.first { $0.name == state.profileName }
            ?? profiles.first { $0.name == BuiltInProfiles.defaultProfileName }
            ?? profiles[0]
        self.activeProfileName = active.name

        var restoredTone = ToneControls()
        if let saved = state.tone, saved.count == 3 {
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
        } else if let stored = state.filters {
            self.currentFilters = Self.normalized(stored)
        } else {
            self.currentFilters = active.filters
        }

        self.currentPreamp = state.preamp.clamped(to: BuiltInProfiles.preampRange)
    }

    // MARK: - Output device

    /// Points the manager at a different output device: the state on screen is
    /// filed under the device it was made for, and whatever that device last
    /// had is loaded in its place.
    ///
    /// A device never seen before starts at the default preset, as a device
    /// never seen before starts at a default volume — inheriting whatever
    /// happened to be playing would make the first switch stick in a way the
    /// user never asked for.
    func setOutputDevice(uid: String?) {
        guard uid != outputDeviceUID else { return }
        persistDeviceState()
        outputDeviceUID = uid

        let state = settings.deviceStates[Self.slot(for: uid)]
            ?? DeviceEQState(profileName: BuiltInProfiles.defaultProfileName)
        apply(state)
    }

    private func apply(_ state: DeviceEQState) {
        let profile = profile(named: state.profileName)
            ?? profile(named: BuiltInProfiles.defaultProfileName)
            ?? builtInProfiles[0]
        activeProfileName = profile.name

        if let saved = state.tone, saved.count == 3 {
            tone = ToneControls(
                bass: saved[0].clamped(to: QuickTone.range),
                mid: saved[1].clamped(to: QuickTone.range),
                treble: saved[2].clamped(to: QuickTone.range)
            )
            currentFilters = Self.applyingTone(tone, to: profile.filters)
        } else {
            tone = ToneControls()
            currentFilters = state.filters.map(Self.normalized) ?? profile.filters
        }
        currentPreamp = state.preamp.clamped(to: BuiltInProfiles.preampRange)
    }

    /// Key for a device's slot. The empty string stands for "no output device",
    /// which no real UID can collide with.
    private static func slot(for uid: String?) -> String { uid ?? "" }

    /// Moves state written before the per-device model into the current
    /// device's slot, so an update doesn't read as having lost the user's EQ.
    /// Runs once: the legacy keys are cleared as they are consumed.
    private static func migratedStateIfNeeded(
        settings: SettingsStore,
        deviceUID: String?
    ) -> DeviceEQState? {
        guard settings.deviceStates.isEmpty, let name = settings.activeProfileName else { return nil }

        var state = DeviceEQState(profileName: name)
        state.filters = settings.workingFilters
        state.preamp = settings.workingPreamp ?? 0
        state.tone = settings.tone

        if state.filters == nil, let legacy = settings.legacyCustomGains,
           legacy.count == BuiltInProfiles.bandCount {
            var chain = BuiltInProfiles.emptyBandChain()
            for slot in 0..<BuiltInProfiles.bandCount {
                chain[slot].gain = legacy[slot].clamped(to: BuiltInProfiles.gainRange)
            }
            state.filters = chain
        }

        settings.deviceStates = [slot(for: deviceUID): state]
        settings.activeProfileName = nil
        settings.workingFilters = nil
        settings.workingPreamp = nil
        settings.tone = nil
        settings.legacyCustomGains = nil
        return state
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

    /// What the filters total at `frequency` — the second number shown at a
    /// band's handle while it is being dragged.
    ///
    /// Deliberately excludes the preamp. That number exists to say "something
    /// else in the chain reaches this band"; a trim that lifts every frequency
    /// by the same amount says nothing about any particular one, and folding it
    /// in would make it differ from the band's own gain on all eleven sliders
    /// the moment the trim left zero. The trim has its own column, and the
    /// curve — which is the output — carries it there.
    ///
    /// This is a readout and never a control: a slider always sets its own
    /// filter's gain, so nothing here can move a knob the user did not touch.
    func totalGain(at frequency: Double, sampleRate: Double) -> Double {
        currentFilters.reduce(0.0) { total, filter in
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
        persistDeviceState()
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
            persistDeviceState()
        }
        renameInDeviceStates(from: name, to: unique)
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
        persistDeviceState()
    }

    func canEditProfile(named name: String) -> Bool {
        userProfiles.contains { $0.name == name }
    }

    // MARK: - Band editing

    func setGain(_ gain: Double, forBandAt slot: Int) {
        guard slot < BuiltInProfiles.bandCount, currentFilters.indices.contains(slot) else { return }
        currentFilters[slot].gain = gain.clamped(to: BuiltInProfiles.gainRange)
        persistDeviceState()
    }

    /// Restores a single band to the active profile's original value
    /// (Lightroom-style double-click reset).
    func resetBand(at slot: Int) {
        let profileBands = getActiveProfile().bandFilters
        guard slot < BuiltInProfiles.bandCount,
              currentFilters.indices.contains(slot),
              profileBands.indices.contains(slot) else { return }
        currentFilters[slot].gain = profileBands[slot].gain
        persistDeviceState()
    }

    /// Switches the whole ladder on or off, for hearing what it contributes on
    /// its own.
    func setBandsEnabled(_ isEnabled: Bool) {
        for slot in 0..<min(BuiltInProfiles.bandCount, currentFilters.count) {
            currentFilters[slot].isEnabled = isEnabled
        }
        persistDeviceState()
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
            q: q.clamped(to: BuiltInProfiles.filterQRange),
            colorIndex: nextColorIndex
        )
        currentFilters.append(filter)
        persistDeviceState()
        return filter.id
    }

    func removeFilter(id: UUID) {
        guard let index = indexOfFreeFilter(id: id) else { return }
        currentFilters.remove(at: index)
        persistDeviceState()
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

    /// Tags a filter with a palette colour. See `BandColor`.
    func setFilterColor(_ colorIndex: Int, id: UUID) {
        updateFreeFilter(id: id) { $0.colorIndex = colorIndex }
    }

    /// The first palette colour no free filter is wearing, so bands added one
    /// after another are told apart at a glance. Once the palette is used up it
    /// cycles, which is the point at which the number beside the swatch is
    /// doing the work anyway.
    private var nextColorIndex: Int {
        let used = Set(freeFilters.map(\.colorIndex))
        return (0..<EQFilter.colorCount).first { !used.contains($0) }
            ?? (freeFilters.count % EQFilter.colorCount)
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
        persistDeviceState()
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
        var lifted = currentFilters[slot].unbound()
        // A band carries the ladder's default colour; as a free filter it needs
        // one of its own, or every lifted band would arrive green.
        lifted.colorIndex = nextColorIndex
        currentFilters[slot].gain = 0
        currentFilters[slot].isEnabled = true
        currentFilters.append(lifted)
        persistDeviceState()
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
        persistDeviceState()
    }

    /// Restores the active profile's chain and re-centres the Quick EQ tone
    /// controls.
    func resetToActiveProfile() {
        tone = ToneControls()
        let profile = getActiveProfile()
        currentFilters = profile.filters
        currentPreamp = profile.preamp
        persistDeviceState()
    }

    // MARK: - Output trim

    func setPreamp(_ dB: Double) {
        currentPreamp = dB.clamped(to: BuiltInProfiles.preampRange)
        persistDeviceState()
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
        persistDeviceState()
    }

    /// Files everything on screen under the current output device.
    ///
    /// One writer for the whole working state, so a new control can't be added
    /// that changes the sound without being remembered alongside the rest.
    private func persistDeviceState() {
        var states = settings.deviceStates
        states[Self.slot(for: outputDeviceUID)] = DeviceEQState(
            profileName: activeProfileName,
            filters: isModified ? currentFilters : nil,
            preamp: currentPreamp,
            tone: tone.isNeutral ? nil : [tone.bass, tone.mid, tone.treble]
        )
        settings.deviceStates = states
    }

    /// Follows a preset rename into every device that had it selected, so the
    /// other devices don't silently fall back to Flat next time they're used.
    private func renameInDeviceStates(from name: String, to newName: String) {
        var states = settings.deviceStates
        for (key, var state) in states where state.profileName == name {
            state.profileName = newName
            states[key] = state
        }
        settings.deviceStates = states
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
