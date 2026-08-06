import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var profileManager = ProfileManager(settings: settings)
    private lazy var audioEngine = AudioEngine(settings: settings)
    private var menuBarController: MenuBarController?
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(
            profileManager: profileManager,
            audioEngine: audioEngine,
            openMainWindow: { [weak self] in self?.showMainWindow() },
            openSettings: { [weak self] in self?.showSettings() }
        )

        let audioEngine = self.audioEngine
        profileManager.$currentFilters
            .sink { audioEngine.apply(filters: $0) }
            .store(in: &cancellables)

        profileManager.$currentPreamp
            .sink { audioEngine.apply(preamp: $0) }
            .store(in: &cancellables)

        audioEngine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioEngine.stop()
    }

    /// Re-launching CoreEQ while it is already running (from Finder, Spotlight,
    /// or `open -a`) brings up the main window rather than doing nothing, which
    /// is the only visible response a menu bar app can give to being "opened".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// Builds the main window around a real `NSSplitViewController`.
    ///
    /// SwiftUI's `NavigationSplitView` only gets Finder's full-height sidebar —
    /// material running to the top of the window with the traffic lights sitting
    /// over it — when SwiftUI owns the window too. Hosted in a hand-made
    /// `NSWindow` it lays the titlebar across both columns instead. An
    /// `NSSplitViewItem(sidebarWithViewController:)` gives that layout directly:
    /// it supplies the vibrant material, sets `allowsFullHeightLayout`, and
    /// keeps its content clear of the window controls via the safe area.
    private func showMainWindow() {
        if mainWindow == nil {
            let splitViewController = NSSplitViewController()

            let sidebar = NSSplitViewItem(
                sidebarWithViewController: NSHostingController(
                    rootView: EqualizerSidebarView(
                        profileManager: profileManager,
                        audioEngine: audioEngine
                    )
                )
            )
            // The setting that actually runs the sidebar material to the top of
            // the window, with the traffic lights sitting over it.
            sidebar.allowsFullHeightLayout = true
            sidebar.minimumThickness = 216
            sidebar.maximumThickness = 300
            // Not collapsible, and no toggle in the toolbar: with the button
            // gone, a sidebar dragged shut would have no way back.
            sidebar.canCollapse = false
            splitViewController.addSplitViewItem(sidebar)

            let contentController = NSHostingController(
                rootView: EqualizerDetailView(
                    profileManager: profileManager,
                    audioEngine: audioEngine,
                    spectrum: audioEngine.spectrum
                )
            )
            // The window must never size itself from its content. By default a
            // hosting controller reports the SwiftUI view's intrinsic size as a
            // preferred size, and AppKit grows the window to satisfy it — so
            // opening the Filters section pushed the window taller than the
            // screen with no way back. The window owns its size; the content
            // lays out inside whatever it is given.
            contentController.sizingOptions = []

            let content = NSSplitViewItem(viewController: contentController)
            content.minimumThickness = 720
            splitViewController.addSplitViewItem(content)

            let window = NSWindow(contentViewController: splitViewController)
            window.title = "CoreEQ"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // Deliberately *not* setting `titlebarAppearsTransparent`: with a
            // unified toolbar and a full-height sidebar item, AppKit already
            // blends the titlebar into both columns, and forcing transparency
            // made it draw as a separate strip above the sidebar instead.
            //
            // The titlebar carries the title, but as a toolbar item rather than
            // the window's own: AppKit suppresses the `toggleSidebar` item
            // whenever the window title is visible, and the toolbar item lands
            // in the same place without costing us the toggle. `window.title`
            // stays set for the Window menu and accessibility.
            window.titleVisibility = .hidden

            // No rule under the titlebar: the page and the titlebar are the same
            // material now, so a separator is the only edge in an otherwise
            // continuous surface, and it reads as a stray line above the
            // Equalizer block.
            //
            // Each split view item resolves its own style and wins over the
            // window's, so all three are set — and set *after* the items are
            // installed, since assigning before `addSplitViewItem` is discarded.
            window.titlebarSeparatorStyle = .none
            sidebar.titlebarSeparatorStyle = .none
            content.titlebarSeparatorStyle = .none
            // `titlebarSeparatorStyle` alone leaves a 1 pt stroke along the
            // bottom of the titlebar — that rule belongs to the opaque titlebar
            // backdrop, not to the separator. Making the titlebar transparent
            // drops the backdrop and its stroke, and the window material behind
            // it is now the same surface the content column draws, so the two
            // meet seamlessly.
            window.titlebarAppearsTransparent = true

            let toolbar = NSToolbar(identifier: "CoreEQMainToolbar")
            toolbar.delegate = self
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            // Unified, not unifiedCompact: System Settings uses the full-height
            // titlebar, and the compact one sits so close to the sidebar's
            // search field that the two run together.
            window.toolbarStyle = .unified

            window.isReleasedWhenClosed = false
            // The minimum is what the fixed sections actually need; every point
            // above it goes to the response graph, which is the point of the
            // window. The opening size is capped to the visible frame so the
            // window always arrives fully on screen, including on a laptop
            // display.
            // The editing area is a fixed height and the graph floor is 120 pt,
            // so the fixed sections come to ~525 pt. The extra width covers the
            // Global Gain column the graph is now inset by.
            window.contentMinSize = NSSize(width: 960, height: 600)
            let visible = (NSScreen.main?.visibleFrame.size).map {
                NSSize(width: min(1_120, $0.width - 80), height: min(760, $0.height - 80))
            } ?? NSSize(width: 1_120, height: 760)
            window.setContentSize(visible)
            window.center()
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens the standard SwiftUI Settings scene. As a menu bar (LSUIElement)
    /// app CoreEQ isn't active when the popover is clicked, so activate first or
    /// the settings window opens behind other apps.
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // `showSettingsWindow:` on macOS 13+, older `showPreferencesWindow:` fallback.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

/// Toolbar for the main window: nothing but the tracking separator that keeps
/// the titlebar's divider aligned with the split.
///
/// The titlebar carries no title or controls — "Equalizer" heads the content
/// column, with the preset menu and Reset beside it, against the graph they act
/// on. The toolbar stays because the sidebar's full-height layout is defined
/// against it.
extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace]
    }
}
