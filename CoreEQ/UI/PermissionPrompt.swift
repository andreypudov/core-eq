import Foundation

/// What to tell the user about the permission, and which button to offer, for
/// each state that needs them.
///
/// One type for the main window's overlay, the General settings row and the
/// menu bar, because the three disagreeing is its own defect: a window saying
/// "Allow…" over a menu saying "not allowed" reads as two problems. Pure, so the
/// mapping can be tested without drawing any of them.
///
/// Before CoreEQ could ask macOS for the answer, every surface showed the same
/// instruction for "never asked" and "refused" — including telling people to
/// turn an already-on switch off and on again. Each state now says only what
/// applies to it.
struct PermissionPrompt: Equatable {
    enum Action: Equatable {
        /// Ask macOS, which shows its prompt.
        case allow
        /// Open the pane where a refusal can be changed. The only thing that
        /// can: macOS asks once and then stops offering.
        case openSystemSettings
        /// Quit and open again. A permission switched on in System Settings
        /// reaches CoreEQ only on its next launch.
        case relaunch

        var title: String {
            switch self {
            case .allow: return "Allow…"
            case .openSystemSettings: return "Open System Settings…"
            case .relaunch: return "Relaunch CoreEQ"
            }
        }
    }

    let title: String
    let explanation: String
    let primary: Action
    /// A quieter second way out, where there is one worth offering.
    let secondary: Action?
    /// The few words a menu row can hold.
    let menuTitle: String

    /// Nil when there is nothing to ask of the user.
    ///
    /// - Parameters:
    ///   - access: what the engine believes about the permission.
    ///   - canAskMacOS: whether TCC can be asked. Without it a refusal cannot be
    ///     told apart from an entry an update left behind, so the denied wording
    ///     has to cover both — which is the one place the old "turn it off and
    ///     on again" advice is still right.
    init?(access: TapAccess, canAskMacOS: Bool = true) {
        switch access {
        case .granted, .unknown:
            return nil
        case .notDetermined:
            title = "CoreEQ needs to reach the sound to change it"
            explanation = Self.whatItIsFor
            primary = .allow
            secondary = nil
            menuTitle = "Allow audio access"
        case .denied:
            title = "CoreEQ is not allowed to process audio"
            // Relaunching is part of the instruction, not an afterthought: macOS
            // settles the permission once per process, so switching it on does
            // nothing for the CoreEQ that is running.
            explanation =
                canAskMacOS
                ? "Turn on CoreEQ under Screen & System Audio Recording, then choose Quit & "
                    + "Reopen when macOS asks."
                : "Turn on CoreEQ under Screen & System Audio Recording. If it is already on, "
                    + "turn it off and on again — an update gives CoreEQ a new signature and "
                    + "macOS keeps the old entry. Then relaunch CoreEQ."
            primary = .openSystemSettings
            secondary = .relaunch
            menuTitle = "Audio permission needed"
        }
    }

    /// What the permission is for, said before macOS asks rather than after.
    /// "System Audio Recording" sounds far broader than what an equalizer does.
    static let whatItIsFor =
        "An equalizer has to reach the sound to change it. CoreEQ reads audio on its way to "
        + "your speakers, adjusts it, and plays it straight back. Nothing is recorded, stored, "
        + "or sent anywhere, and quitting CoreEQ hands the audio back immediately."
}
