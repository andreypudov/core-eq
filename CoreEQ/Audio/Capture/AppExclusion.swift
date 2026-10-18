import CoreAudio
import Foundation

/// Apps CoreEQ leaves alone: their sound goes straight to the output, never
/// through the tap.
///
/// Asked for by a musician who needs a DAW and the rest of a mastering chain
/// heard as they are, while everything else stays corrected (#20). A flat
/// preset is not the same thing — flat audio still enters the tap and comes
/// back — and exclusion is the one honest form of "bit-perfect" this design
/// has.
///
/// By bundle identifier, on macOS 26 and later, because that is what lets the
/// system do the hard part. Measured on macOS 27 with a tone per app:
///
/// - `CATapDescription.bundleIDs` excludes an app whether or not it is running
///   when the tap is made, alongside the process list CoreEQ already uses to
///   leave itself out, and on the device-bound taps as well as the global one.
///   An identifier that matches nothing is ignored.
/// - `processRestoreEnabled` is what keeps it excluded. Without it an app that
///   launches, or quits and comes back, after the tap was made is tapped like
///   any other — the exclusion holds only for the processes alive at the time.
/// - Apps that play through a helper process cannot be excluded this way.
///   Safari's sound comes from `com.apple.WebKit.GPU`; excluding Safari's
///   identifier, or even the helper's, left it in the tap. Only the helper's
///   process object removed it, and that helper serves every WebKit app at
///   once. So the list offers apps, not helpers — see `isStandaloneApp(at:)`.
///
/// Before macOS 26 the identifiers would have to be turned into process objects
/// by hand and followed through every launch and quit. Not done: it is a second
/// implementation of what the system now does, for a shrinking set of Macs.
enum AppExclusion {
    /// Whether this Mac can exclude apps at all.
    static var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// The list as it should be stored: trimmed, without blanks or repeats, and
    /// without CoreEQ itself, which is always left out of the tap by process
    /// and has no business being listed as a choice. Order is kept, so the list
    /// reads in the order things were added.
    static func normalized(
        _ bundleIDs: [String], ownBundleID: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        var seen = Set<String>()
        let own = ownBundleID?.lowercased()
        return
            bundleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty && $0.lowercased() != own && seen.insert($0.lowercased()).inserted
            }
    }

    /// Makes `description` leave the given apps out.
    ///
    /// An empty list leaves the description exactly as it was, so a Mac with
    /// nothing excluded gets the same tap every earlier version made.
    static func apply(_ bundleIDs: [String], to description: CATapDescription) {
        guard !bundleIDs.isEmpty else { return }
        if #available(macOS 26, *) {
            description.bundleIDs = bundleIDs
            // Set rather than relied on. A fresh description reported it on,
            // but an exclusion that silently stops at the next relaunch is the
            // failure this would be, and nothing documents the default.
            description.isProcessRestoreEnabled = true
        }
    }

    /// Whether a change to the list should rebuild the audio path now.
    ///
    /// While running — idle included, since an idle engine keeps its tap and
    /// would bring the old list back with the next sound — and after a
    /// failure, because the list can be its cause. With only excluded apps
    /// playing, a tap that had not yet heard anything was judged not
    /// capturing, and a switch that then did nothing left no way out short of
    /// quitting. Stopped, or waiting for permission, there is nothing to
    /// rebuild, and the next start reads the list anyway.
    static func rebuildsOnChange(isRunning: Bool, hasFailed: Bool) -> Bool {
        isRunning || hasFailed
    }

    /// Whether `url` is an application someone would recognise, rather than a
    /// helper living inside one.
    ///
    /// Helpers are where exclusion does not work, and they are what an audio
    /// process list is full of: `com.apple.WebKit.GPU` is an XPC service inside
    /// a framework, and Chromium-based apps play through a `.app` nested in
    /// their own bundle's frameworks. Offering either would offer a choice that
    /// does nothing.
    static func isStandaloneApp(at url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        guard let last = components.last, last.hasSuffix(".app") else { return false }
        let containers = [".app", ".appex", ".xpc", ".framework", ".bundle"]
        return !components.dropLast().contains { component in
            containers.contains { component.hasSuffix($0) }
        }
    }
}

/// The Exclusions pane's list: every app on it, and the ones switched on.
///
/// Each edit returns the list as it should be stored, normalised the way
/// `AppExclusion.normalized` stores it, so the pane cannot write a list with
/// repeats or with CoreEQ itself on it.
struct ExclusionList: Equatable {
    /// Every listed app, in the order it was added.
    var listed: [String]
    /// The listed apps switched on: the ones the tap leaves out.
    var excluded: [String]

    /// Adds apps, switched on: adding one is asking for it to be left out. An
    /// app already listed with its switch off is switched back on.
    func adding(
        _ bundleIDs: [String], ownBundleID: String? = Bundle.main.bundleIdentifier
    )
        -> ExclusionList
    {
        normalized(listed: listed + bundleIDs, excluded: excluded + bundleIDs, own: ownBundleID)
    }

    /// Takes an app off the list altogether.
    func removing(
        _ bundleID: String, ownBundleID: String? = Bundle.main.bundleIdentifier
    )
        -> ExclusionList
    {
        normalized(
            listed: listed.filter { $0 != bundleID },
            excluded: excluded.filter { $0 != bundleID }, own: ownBundleID)
    }

    /// Switches one listed app on or off. Off keeps it listed, so it can have
    /// its EQ back for a while without being forgotten.
    func setting(
        _ bundleID: String, excluded isOn: Bool,
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) -> ExclusionList {
        normalized(
            listed: listed,
            excluded: isOn ? excluded + [bundleID] : excluded.filter { $0 != bundleID },
            own: ownBundleID)
    }

    /// Whether going from `self` to `other` changes what the tap leaves out.
    /// Only that is worth the break in the sound a rebuild costs; listing or
    /// removing a switched-off app is not.
    func changesTap(comparedTo other: ExclusionList) -> Bool {
        excluded != other.excluded
    }

    /// Identifiers are compared without case, so an excluded app takes the
    /// spelling of its row. Otherwise the same app added as `com.apple.Logic10`
    /// beside a listed `com.apple.logic10` would be left out while its switch,
    /// which looks for the row's spelling, showed it off.
    private func normalized(listed: [String], excluded: [String], own: String?) -> ExclusionList {
        let rows = AppExclusion.normalized(listed, ownBundleID: own)
        let spelling = Dictionary(
            rows.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return ExclusionList(
            listed: rows,
            excluded: AppExclusion.normalized(excluded, ownBundleID: own).map {
                spelling[$0.lowercased()] ?? $0
            })
    }
}
