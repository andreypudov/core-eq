import Foundation

/// Opening a window from a status menu.
///
/// A menu item's action runs inside the menu's own tracking loop, and a window
/// presented from there arrives *behind* other applications: an accessory app is
/// not frontmost when its menu is clicked, and the activation that would bring
/// it forward does not reliably take while the menu is still up. The window
/// orders in regardless, so it appears — just underneath whatever was in front.
/// Whether it wins is a race with the menu dismissing, which is why the bug is
/// intermittent.
///
/// Deferring by one turn of the run loop lets the menu close first, after which
/// activation means what it says.
///
/// A named operation rather than a bare `DispatchQueue.main.async` at each call
/// site, because at the call site the deferral looks like indirection for its
/// own sake and invites being tidied away.
@MainActor
enum MenuPresentation {

    /// How the work is deferred. Substituted only by tests, which have no menu
    /// to wait for and need the timing to be theirs to decide.
    typealias Schedule = (@escaping @MainActor () -> Void) -> Void

    /// The next turn of the main run loop, by which time the menu has gone.
    static let afterThisRunLoopTurn: Schedule = { present in
        DispatchQueue.main.async { MainActor.assumeIsolated(present) }
    }

    /// Presents once the menu that triggered it has closed.
    ///
    /// - Parameters:
    ///   - schedule: how to defer. The default is the only correct answer
    ///     outside a test.
    ///   - present: the presentation. Must not be run synchronously — that is
    ///     the whole point.
    static func afterMenuCloses(
        using schedule: Schedule = afterThisRunLoopTurn,
        _ present: @escaping @MainActor () -> Void
    ) {
        schedule(present)
    }
}
