import Foundation

/// Whether the engine may start, or has to explain itself first.
///
/// Its own type, and pure, because this is the decision the whole "explain
/// before the system prompt" feature rests on, and the engine it belongs to
/// cannot be reached by a test.
enum AudioPermissionGate {

    /// What to offer someone whose permission is not in hand.
    enum Offer: Equatable {
        /// Ask macOS, which will raise its prompt.
        case askTheSystem
        /// Asking was refused. macOS will not offer again while that refusal
        /// stands, so System Settings is the only thing that can change it.
        case openSystemSettings
    }

    enum Decision: Equatable {
        /// The permission is granted. Start, and say nothing.
        case start
        /// Wait, explain, and offer this.
        case explainFirst(Offer)
    }

    /// - Parameters:
    ///   - isGranted: whether the system reports the permission as held. This
    ///     can be answered without prompting.
    ///   - wasRefused: whether an attempt to capture was actually refused.
    /// - Returns: `.start` when the permission is in hand, otherwise what to
    ///   explain and offer.
    ///
    /// The engine never starts without the permission, even when it has asked
    /// before. That is the guarantee: creating the tap is what raises the system
    /// prompt, so any path that starts hopefully is a path where the prompt can
    /// appear with nothing said beforehand — which is the whole problem this
    /// exists to solve. It happens in practice whenever the two facts disagree,
    /// as they do after a rebuild: CoreEQ remembers asking, macOS does not.
    /// Offering System Settings turns on a refusal that happened, not on
    /// CoreEQ having asked before. Those look like the same question and are
    /// not: macOS forgets its answer whenever the app's identity changes — a
    /// rebuild, a re-signed release — and then prompts as if for the first time.
    /// Treating "we asked once" as "it will not ask again" sends someone to
    /// System Settings to hunt for a switch, when a button here would have
    /// raised the prompt for them.
    static func decision(isGranted: Bool, wasRefused: Bool) -> Decision {
        guard !isGranted else { return .start }
        return .explainFirst(wasRefused ? .openSystemSettings : .askTheSystem)
    }
}
