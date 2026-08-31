import Combine
import Foundation

/// Holds the built-in profiles, any presets the user created, the active
/// selection, and the working chain (the active profile plus any edits since).
/// Persists the selection, the user presets, and the working chain through
/// `SettingsStore` and restores them on launch.
///
/// The chain is kept normalised — see `FilterChain` — so the slider strip is
/// always exactly eleven controls that index straight into the array, no matter
/// what the user has added.
///
/// What this class does *not* hold: the preset collection is `PresetLibrary`,
/// chain arithmetic is `FilterChain`, and what a stored device slot means is
/// `DeviceEQState.resolved(against:)`. What is left here is orchestration —
/// deciding when things happen, and keeping the published state, the engine and
/// the defaults in step.
@MainActor
final class ProfileManager: ObservableObject {
    /// The three menu-bar Quick EQ tone positions. See `QuickTone`.
    struct ToneControls: Equatable {
        var bass: Double = 0
        var mid: Double = 0
        var treble: Double = 0

        var isNeutral: Bool { self == ToneControls() }
    }

    /// Every preset CoreEQ knows about. See `PresetLibrary` — a value type, so
    /// changing it republishes without any nested-observation plumbing.
    @Published private(set) var library: PresetLibrary

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

    /// Whether the trim is being computed from the chain. See `AutoGain`.
    @Published private(set) var isAutoGain = false

    /// Which of the two working states is being heard. See `ABSlot`.
    @Published private(set) var abSlot: ABSlot = .a

    /// The state not currently being heard, kept so switching back is exact.
    /// Nil until the user has reached for the other slot once.
    private var alternate: WorkingState?

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
        // Falling back to the device this app was last filing under, because
        // "Core Audio has no answer yet" and "there is genuinely no device" look
        // identical here and only one of them is true at launch. Picking the
        // remembered device restores the session the user actually left; picking
        // nothing files everything they then do into a slot no real device ever
        // reads again, which is how a no-device slot ends up holding a real
        // preset and a real A/B pair.
        let device = outputDeviceUID ?? settings.lastOutputDeviceUID
        self.outputDeviceUID = device
        if device != nil { settings.lastOutputDeviceUID = device }

        let library = PresetLibrary(stored: settings.userProfiles)
        self.library = library

        let state =
            Self.migratedStateIfNeeded(settings: settings, deviceUID: device)
            ?? settings.deviceStates[Self.slot(for: device)]
            ?? DeviceEQState(profileName: BuiltInProfiles.defaultProfileName)

        let resolved = state.resolved(against: library.all)
        self.activeProfileName = resolved.profileName
        self.currentFilters = resolved.filters
        self.currentPreamp = resolved.preamp
        self.tone = ToneControls(bass: resolved.bass, mid: resolved.mid, treble: resolved.treble)
        self.isAutoGain = resolved.autoGain
        self.abSlot = state.liveSlot
        self.alternate = state.alternate
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
        // Nil is the absence of a device, not a different one. Pull a jack and
        // the system default is briefly nothing at all before the fallback
        // appears, and treating that gap as a device change swaps the whole
        // working state into the no-device slot: the preset on screen is
        // replaced by whatever was last filed there, and the chain being
        // listened to is filed away under no device — which is how a slot keyed
        // on nothing ends up holding a real preset and a real chain.
        //
        // Holding still is also what the user sees. Moving a cable is not an
        // edit, and the sound should not change because the hardware blinked.
        guard let uid else { return }
        guard uid != outputDeviceUID else { return }
        persistDeviceState()
        outputDeviceUID = uid
        settings.lastOutputDeviceUID = uid

        let state =
            settings.deviceStates[Self.slot(for: uid)]
            ?? DeviceEQState(profileName: BuiltInProfiles.defaultProfileName)
        apply(state)
    }

    private func apply(_ state: DeviceEQState) {
        let resolved = state.resolved(against: profiles)
        activeProfileName = resolved.profileName
        currentFilters = resolved.filters
        currentPreamp = resolved.preamp
        tone = ToneControls(bass: resolved.bass, mid: resolved.mid, treble: resolved.treble)
        isAutoGain = resolved.autoGain
        abSlot = state.liveSlot
        alternate = state.alternate
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
        guard settings.deviceStates.isEmpty, let name = settings.activeProfileName else {
            return nil
        }

        var state = DeviceEQState(profileName: name)
        state.filters = settings.workingFilters
        state.preamp = settings.workingPreamp ?? 0
        state.tone = settings.tone

        if state.filters == nil, let legacy = settings.legacyCustomGains,
            legacy.count == BuiltInProfiles.bandCount
        {
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
    var profiles: [EQProfile] { library.all }

    /// The preset the working chain was loaded from. Everything "unsaved" is
    /// measured against this.
    var activeProfile: EQProfile {
        library.profile(named: activeProfileName) ?? library.builtIn[0]
    }

    /// The two groups the sidebar lists, filtered by what was typed into its
    /// search field.
    ///
    /// Substring rather than prefix matching, so "boost" finds Bass Booster and
    /// Treble Booster — a list of twenty-odd names is searched by the word you
    /// remember, which is rarely the first one. Case and diacritics are ignored
    /// so a preset named "Café" answers to "cafe".
    ///
    /// Lives here rather than in the sidebar because it is a question about the
    /// preset library, and because a view is a place tests cannot reach.
    func profiles(matching term: String) -> (user: [EQProfile], builtIn: [EQProfile]) {
        library.matching(term)
    }

    func profile(named name: String) -> EQProfile? {
        library.profile(named: name)
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
        // A preset carries whether its trim is computed, so selecting one adopts
        // that too — `chainDidChange` then supplies the number.
        isAutoGain = profile.autoGain
        chainDidChange()
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
        let stored = library.add(
            EQProfile(
                name: name,
                filters: filters ?? currentFilters,
                preamp: preamp ?? currentPreamp,
                autoGain: isAutoGain
            )
        )
        persistUserProfiles()
        setActiveProfile(name: stored)
        profileAwaitingRename = stored
        return stored
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
        return addProfile(
            named: "\(source.name) copy", filters: source.filters, preamp: source.preamp)
    }

    /// Renames a user preset. Built-in profiles and empty names are ignored, and
    /// a name that collides with an existing profile gets a numeric suffix.
    @discardableResult
    func renameProfile(named name: String, to newName: String) -> String? {
        guard let unique = library.rename(name, to: newName) else { return nil }
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
        guard let fallback = library.remove(name) else { return }
        persistUserProfiles()
        if profileAwaitingRename == name { profileAwaitingRename = nil }

        // Only the preset being listened to needs replacing; deleting any other
        // leaves the sound alone.
        if activeProfileName == name { setActiveProfile(name: fallback) }
    }

    /// Writes the working chain into the active user preset, so the current
    /// sound — bands and free filters together — becomes the preset's saved
    /// state.
    func saveChangesToActiveProfile() {
        guard library.isEditable(activeProfileName) else { return }
        library.update(
            activeProfileName,
            filters: currentFilters,
            preamp: currentPreamp,
            autoGain: isAutoGain
        )
        persistUserProfiles()
        tone = ToneControls()
        chainDidChange()
    }

    func canEditProfile(named name: String) -> Bool {
        library.isEditable(name)
    }

    // MARK: - Band editing

    func setGain(_ gain: Double, forBandAt slot: Int) {
        guard slot < BuiltInProfiles.bandCount, currentFilters.indices.contains(slot) else {
            return
        }
        currentFilters[slot].gain = gain.clamped(to: BuiltInProfiles.gainRange)
        chainDidChange()
    }

    /// Restores a single band to the active profile's original value
    /// (Lightroom-style double-click reset).
    func resetBand(at slot: Int) {
        let profileBands = activeProfile.bandFilters
        guard slot < BuiltInProfiles.bandCount,
            currentFilters.indices.contains(slot),
            profileBands.indices.contains(slot)
        else { return }
        currentFilters[slot].gain = profileBands[slot].gain
        chainDidChange()
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
        chainDidChange()
        return filter.id
    }

    func removeFilter(id: UUID) {
        guard let index = indexOfFreeFilter(id: id) else { return }
        currentFilters.remove(at: index)
        chainDidChange()
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
            currentFilters.indices.contains(slot)
        else { return nil }
        var lifted = currentFilters[slot].unbound()
        // A band carries the ladder's default colour; as a free filter it needs
        // one of its own, or every lifted band would arrive green.
        lifted.colorIndex = nextColorIndex
        currentFilters[slot].gain = 0
        currentFilters[slot].isEnabled = true
        currentFilters.append(lifted)
        chainDidChange()
        return lifted.id
    }

    // MARK: - A/B

    /// Puts the other working state in front.
    ///
    /// Both slots hold a complete sound — preset, chain, trim, tone — so this is
    /// a comparison rather than an undo: everything about what you were hearing
    /// is kept, and comes back untouched when you switch again.
    ///
    /// A slot reached for the first time starts as a copy of the one it replaces,
    /// which is what makes the first switch silent. Starting it at Flat would
    /// mean the first thing A/B ever did was change the sound, and the point of
    /// the control is to change nothing until you ask it to.
    func setSlot(_ slot: ABSlot) {
        guard slot != abSlot else { return }

        var state = currentDeviceState()
        state.swapSlots()

        abSlot = state.liveSlot
        alternate = state.alternate

        let resolved = state.resolved(against: profiles)
        activeProfileName = resolved.profileName
        currentFilters = resolved.filters
        currentPreamp = resolved.preamp
        tone = ToneControls(bass: resolved.bass, mid: resolved.mid, treble: resolved.treble)
        isAutoGain = resolved.autoGain

        persistDeviceState()
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

        let profileBands = activeProfile.bandFilters
        let offsets = QuickTone.offsets(bass: tone.bass, mid: tone.mid, treble: tone.treble)
        for slot in 0..<min(BuiltInProfiles.bandCount, currentFilters.count) {
            let base = profileBands[safe: slot]?.gain ?? 0
            currentFilters[slot].gain = (base + offsets[slot]).clamped(
                to: BuiltInProfiles.gainRange)
        }
        chainDidChange()
    }

    /// Restores the active profile's chain and re-centres the Quick EQ tone
    /// controls.
    func resetToActiveProfile() {
        tone = ToneControls()
        let profile = activeProfile
        currentFilters = profile.filters
        currentPreamp = profile.preamp
        isAutoGain = profile.autoGain
        chainDidChange()
    }

    // MARK: - Output trim

    /// Sets the trim by hand. Ignored while the trim is being computed — the
    /// control is disabled then, so this can only be reached by a caller that
    /// has not looked.
    func setPreamp(_ dB: Double) {
        guard !isAutoGain else { return }
        currentPreamp = dB.clamped(to: BuiltInProfiles.preampRange)
        persistDeviceState()
    }

    /// Turns the computed trim on or off.
    ///
    /// Switching it on takes the trim over immediately, so the effect is audible
    /// at the moment the user asks for it rather than at the next edit.
    /// Switching it off leaves the number where the computation had it — the
    /// slider becomes yours again at the value you were already hearing, which
    /// is the only value that makes the transition silent.
    func setAutoGain(_ isOn: Bool) {
        guard isOn != isAutoGain else { return }
        isAutoGain = isOn
        if isOn { currentPreamp = AutoGain.trim(for: currentFilters) }
        persistDeviceState()
    }

    /// Called by everything that changes the chain: recomputes the trim when it
    /// is being computed, then files the result.
    ///
    /// One funnel rather than a recomputation at each of the sixteen call sites,
    /// so a new way to edit the chain cannot forget to keep the trim in step.
    private func chainDidChange() {
        if isAutoGain {
            currentPreamp = AutoGain.trim(for: currentFilters)
        }
        persistDeviceState()
    }

    /// Whether the working state differs from the preset it came from — what
    /// puts "Edited" in the header and what decides whether a device's slot has
    /// a chain worth storing.
    ///
    /// Read on the drag path, so the preset is looked up once rather than once
    /// per term.
    var isModified: Bool {
        let profile = activeProfile
        if currentFilters != profile.filters { return true }
        if isAutoGain != profile.autoGain { return true }
        // With Auto on the trim is derived from the chain, so it says nothing
        // the chain has not already been compared for. Comparing it against the
        // preset's stored number would mark every computed preset as edited the
        // moment it was selected — the number on screen is what the preset asks
        // for, not a departure from it.
        return isAutoGain ? false : currentPreamp != profile.preamp
    }

    // MARK: - Private

    private func indexOfFreeFilter(id: UUID) -> Int? {
        guard let index = currentFilters.firstIndex(where: { $0.id == id }),
            index >= BuiltInProfiles.bandCount
        else { return nil }
        return index
    }

    private func updateFreeFilter(id: UUID, _ change: (inout EQFilter) -> Void) {
        guard let index = indexOfFreeFilter(id: id) else { return }
        change(&currentFilters[index])
        chainDidChange()
    }

    /// Files everything on screen under the current output device.
    ///
    /// One writer for the whole working state, so a new control can't be added
    /// that changes the sound without being remembered alongside the rest.
    private func persistDeviceState() {
        var states = settings.deviceStates
        states[Self.slot(for: outputDeviceUID)] = currentDeviceState()
        settings.deviceStates = states
    }

    /// Everything on screen, as the device's slot would store it.
    private func currentDeviceState() -> DeviceEQState {
        DeviceEQState(
            profileName: activeProfileName,
            filters: isModified ? currentFilters : nil,
            preamp: currentPreamp,
            tone: tone.isNeutral ? nil : [tone.bass, tone.mid, tone.treble],
            autoGain: isAutoGain,
            alternate: alternate,
            liveSlot: abSlot
        )
    }

    /// Follows a preset rename into every device that had it selected, so the
    /// other devices don't silently fall back to Flat next time they're used.
    private func renameInDeviceStates(from name: String, to newName: String) {
        var states = settings.deviceStates
        for (key, var state) in states {
            var changed = false
            if state.profileName == name {
                state.profileName = newName
                changed = true
            }
            // The slot nobody is listening to refers to presets by name as well,
            // and would otherwise fall back to Flat the next time it came round.
            if state.alternate?.profileName == name {
                state.alternate?.profileName = newName
                changed = true
            }
            if changed { states[key] = state }
        }
        settings.deviceStates = states

        if alternate?.profileName == name {
            alternate?.profileName = newName
        }
    }

    private func persistUserProfiles() {
        settings.userProfiles = library.user
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
