import Foundation

/// The presets CoreEQ knows about: the ones it ships with, and the ones the user
/// made.
///
/// A value type on purpose. The obvious alternative — a second `ObservableObject`
/// owned by `ProfileManager` — publishes nothing to the views observing the
/// manager, because SwiftUI does not follow nested observation. Held as a plain
/// stored property of the manager, every mutation republishes for free, and the
/// library itself can be built, exercised and compared in a test without a
/// manager, a `SettingsStore`, or a main actor.
///
/// The library is deliberately *not* per device. Presets are a collection you
/// own; only which one is playing follows the hardware.
struct PresetLibrary: Equatable {
    /// Shipped with CoreEQ. Read-only: they can be duplicated, never edited.
    let builtIn: [EQProfile]

    /// The user's own. Renameable, editable, deletable.
    private(set) var user: [EQProfile]

    /// Built-ins first, then the user's own — the order the sidebar and the menu
    /// present them in.
    var all: [EQProfile] { builtIn + user }

    /// Builds a library from what was stored, dropping any preset whose name
    /// collides with a built-in or with an earlier entry.
    ///
    /// Names are identity here — the sidebar, the menu and every device's stored
    /// state refer to a preset by name — so duplicates are not a cosmetic
    /// problem but two rows that cannot be told apart.
    init(builtIn: [EQProfile] = BuiltInProfiles.all, stored: [EQProfile] = []) {
        self.builtIn = builtIn

        var seen = Set(builtIn.map(\.name))
        self.user = stored
            .filter { seen.insert($0.name).inserted }
            .map { EQProfile(name: $0.name, filters: FilterChain.normalized($0.filters), preamp: $0.preamp, autoGain: $0.autoGain) }
    }

    // MARK: - Reading

    func profile(named name: String) -> EQProfile? {
        // Built-ins are searched first and are the common case; only a user
        // preset pays for the second pass.
        builtIn.first { $0.name == name } ?? user.first { $0.name == name }
    }

    func isEditable(_ name: String) -> Bool {
        user.contains { $0.name == name }
    }

    /// The two groups the sidebar lists, filtered by what was typed into its
    /// search field.
    ///
    /// Substring rather than prefix matching, so "boost" finds Bass Booster and
    /// Treble Booster — a list of twenty-odd names is searched by the word you
    /// remember, which is rarely the first one. Case and diacritics are ignored,
    /// so a preset named "Café" answers to "cafe".
    func matching(_ term: String) -> (user: [EQProfile], builtIn: [EQProfile]) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (user, builtIn) }

        func keep(_ profiles: [EQProfile]) -> [EQProfile] {
            profiles.filter {
                $0.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return (keep(user), keep(builtIn))
    }

    /// `name` if no profile uses it, otherwise "name 2", "name 3", …
    func uniqueName(from name: String) -> String {
        let taken = Set(all.map(\.name))
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) \(suffix)") {
            suffix += 1
        }
        return "\(name) \(suffix)"
    }

    // MARK: - Writing

    /// Adds a preset under a name made unique, and returns that name.
    @discardableResult
    mutating func add(_ profile: EQProfile) -> String {
        var stored = profile
        stored.name = uniqueName(from: profile.name)
        stored.isBuiltIn = false
        user.append(stored)
        return stored.name
    }

    /// Renames a user preset, returning the name it actually took, or nil when
    /// there was nothing to rename or nothing to rename it to.
    @discardableResult
    mutating func rename(_ name: String, to newName: String) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = user.firstIndex(where: { $0.name == name }),
              !trimmed.isEmpty,
              trimmed != name
        else { return nil }

        let unique = uniqueName(from: trimmed)
        user[index].name = unique
        return unique
    }

    /// Removes a user preset and reports what should be selected instead: the
    /// preset that took its place in the list, the one before it, or the
    /// default when none is left.
    @discardableResult
    mutating func remove(_ name: String) -> String? {
        guard let index = user.firstIndex(where: { $0.name == name }) else { return nil }
        user.remove(at: index)
        return user[safe: index]?.name
            ?? user[safe: index - 1]?.name
            ?? BuiltInProfiles.defaultProfileName
    }

    /// Writes a sound into an existing user preset. Built-ins are ignored — that
    /// is what makes them built in.
    mutating func update(
        _ name: String, filters: [EQFilter], preamp: Double, autoGain: Bool
    ) {
        guard let index = user.firstIndex(where: { $0.name == name }) else { return }
        user[index].filters = filters
        user[index].preamp = preamp
        user[index].autoGain = autoGain
    }
}
