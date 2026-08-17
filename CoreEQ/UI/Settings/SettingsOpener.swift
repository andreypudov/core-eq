import AppKit
import SwiftUI
import os

/// Opens the Settings scene from AppKit code.
///
/// `NSApp.sendAction(Selector(("showSettingsWindow:")))` no longer works — and,
/// worse, it *returns true* while doing nothing, so the failure is silent. The
/// supported route is SwiftUI's own `SettingsLink` / `openSettings`, and neither
/// can be called from an `NSMenuItem` action directly:
///
/// - `SettingsLink` is a view. Hosting one and clicking it programmatically is
///   the folk remedy, and it cannot work: SwiftUI draws its own controls, so a
///   hosted `SettingsLink` contains no `NSButton` to send `performClick` to.
/// - `EnvironmentValues.openSettings` is the same mechanism as an action, but an
///   environment value only exists inside a SwiftUI view.
///
/// So this hosts a one-point transparent SwiftUI view, reads the action out of
/// its environment, and keeps it. The host has to be inside a real window —
/// `onAppear` never fires for a hosting view that belongs to no window, and the
/// action is never captured — which is why `install(in:)` takes the status
/// item's button rather than making a window of its own.
@MainActor
final class SettingsOpener {
    private var openSettings: (() -> Void)?
    private var host: NSView?
    private let logger = Logger(subsystem: "com.andreypudov.coreeq", category: "Settings")

    /// Attaches the capture view to something already on screen. Call once, with
    /// a view that lives in a window for the lifetime of the app.
    func install(in view: NSView) {
        guard host == nil else { return }

        let capture = NSHostingView(
            rootView: SettingsActionCapture { [weak self] action in
                self?.openSettings = action
            }
        )
        capture.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        capture.alphaValue = 0
        // Invisible and untouchable: it exists to be in a view hierarchy, not to
        // be seen or clicked.
        capture.isHidden = false
        view.addSubview(capture)
        host = capture
    }

    func open() {
        // An accessory application is not frontmost when its status menu is
        // clicked, so the window would otherwise open behind whatever is.
        NSApp.activate(ignoringOtherApps: true)

        guard let openSettings else {
            logger.error("Settings action unavailable; the capture view never appeared.")
            return
        }
        openSettings()
    }
}

/// Hands its `openSettings` environment action to whoever installed it.
private struct SettingsActionCapture: View {
    let onReady: (@escaping () -> Void) -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { onReady { openSettings() } }
    }
}
