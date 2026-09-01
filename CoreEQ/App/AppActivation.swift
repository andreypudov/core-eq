import AppKit

/// Bringing CoreEQ to the front.
///
/// An accessory application is never frontmost when its status menu is clicked,
/// so anything it opens arrives behind whatever is — unless it activates first.
///
/// `ignoringOtherApps` deliberately, deprecated or not. The replacement,
/// `NSApp.activate()`, goes through cooperative activation and may simply
/// decline while another app holds focus, which is exactly the situation every
/// call from a status menu is in. Declining leaves the window ordered in but
/// underneath. This was changed to the non-deprecated call once, and the main
/// window began opening behind Xcode.
///
/// Both windows CoreEQ can open need this and neither owns the other, so the
/// reasoning lives here rather than in two copies that can drift apart.
///
/// Timing is a separate problem with a separate answer: activation does not
/// reliably take while the menu that triggered it is still up. See
/// `MenuPresentation`, which every menu-driven caller goes through first.
@MainActor
enum AppActivation {

    /// Activates CoreEQ, for a window it does not own — the Settings scene
    /// belongs to SwiftUI, which orders it in itself.
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Activates CoreEQ and brings `window` forward.
    ///
    /// `orderFrontRegardless` follows `makeKeyAndOrderFront` rather than
    /// replacing it: if activation is refused anyway the window is still shown
    /// rather than left underneath, because the user asked for it by name.
    static func bringForward(_ window: NSWindow) {
        activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
