import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()

    /// Owned here rather than by the window, so device changes are followed
    /// whether or not anything is on screen — the EQ has to follow the hardware
    /// even when CoreEQ is only a menu bar icon.
    private let outputs = AudioDeviceList()

    private lazy var profileManager = ProfileManager(
        settings: settings,
        outputDeviceUID: outputs.defaultDevicePersistentID
    )
    private lazy var audioEngine = AudioEngine(settings: settings)
    private var menuBarController: MenuBarController?
    private var mainWindow: NSWindow?
    /// Held because the toolbar's tracking separator needs the split view, and
    /// the toolbar is asked for its items while the window is still being built.
    private var splitViewController: NSSplitViewController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(
            profileManager: profileManager,
            audioEngine: audioEngine,
            outputs: outputs,
            openMainWindow: { [weak self] in self?.showMainWindow() }
        )

        let audioEngine = self.audioEngine
        profileManager.$currentFilters
            .sink { audioEngine.apply(filters: $0) }
            .store(in: &cancellables)

        profileManager.$currentPreamp
            .sink { audioEngine.apply(preamp: $0) }
            .store(in: &cancellables)

        // Each output device keeps its own preset, edits, trim, and tone — the
        // way macOS keeps a volume per device. Switching outputs loads that
        // device's sound.
        let profileManager = self.profileManager
        let outputs = self.outputs
        outputs.$defaultDeviceID
            .removeDuplicates()
            .sink { _ in
                profileManager.setOutputDevice(uid: outputs.defaultDevicePersistentID)
            }
            .store(in: &cancellables)

        // The Settings window is a separate scene and cannot be handed the
        // engine, so the one fact it needs crosses on its own.
        EngineStatusBridge.shared.follow(audioEngine)

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
            self.splitViewController = splitViewController

            let sidebar = NSSplitViewItem(
                sidebarWithViewController: NSHostingController(
                    rootView: EqualizerSidebarView(profileManager: profileManager)
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
                    spectrum: audioEngine.spectrum,
                    outputs: outputs
                )
            )
            // The window must never size itself from its content. By default a
            // hosting controller reports the SwiftUI view's intrinsic size as a
            // preferred size, and AppKit grows the window to satisfy it — so
            // opening the Filters section pushed the window taller than the
            // screen with no way back. The window owns its size; the content
            // lays out inside whatever it is given.
            contentController.sizingOptions = []
            // The content column runs to the top of the window rather than
            // starting below the titlebar. Without this it is inset by the
            // titlebar height to match the sidebar, which leaves an empty strip
            // above the Equalizer heading; with it, the heading and its controls
            // sit level with the traffic lights, as they should.
            contentController.safeAreaRegions = []

            let content = NSSplitViewItem(viewController: contentController)
            content.minimumThickness = 720
            splitViewController.addSplitViewItem(content)

            let window = NSWindow(contentViewController: splitViewController)
            window.title = "CoreEQ"
            window.styleMask = [
                .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
            ]
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
            // Header, editing area, and padding come to ~400 pt — the strip
            // spends 40 of that on `Theme.BandRow.chromeHeight`, a value row
            // above each track and a caption below. The rest is the graph,
            // which has a 120 pt floor.
            window.contentMinSize = NSSize(width: 960, height: 540)
            let visible =
                (NSScreen.main?.visibleFrame.size).map {
                    NSSize(width: min(1_120, $0.width - 80), height: min(760, $0.height - 80))
                } ?? NSSize(width: 1_120, height: 760)
            window.setContentSize(visible)
            window.center()
            // Closing this window only orders it out — SwiftUI's `onDisappear`
            // never fires, so without a delegate the spectrum analyzer would
            // keep running its 60 Hz timer against a window nobody can see.
            window.delegate = self
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        // Nothing starts out focused.
        //
        // This window is closed by ordering out and reopened by ordering back
        // in, and AppKit restores the first responder it had — which, once a
        // parametric band exists, is a text field holding a number, arriving
        // selected and ready to be typed over by anyone who reopens the window
        // and presses a key. Clearing it twice: once now, and once after the
        // window has finished becoming key, since the key-view loop is settled
        // by then and can otherwise hand the focus straight back.
        mainWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in
            self?.mainWindow?.makeFirstResponder(nil)
        }
        audioEngine.spectrum.start()
    }

}

/// Analysis follows the window's visibility.
///
/// The analyzer drives the plot's backdrop and nothing else, so it should run
/// only while there is a plot on screen. `orderOut:` doesn't remove the hosting
/// view from its window, so the view's own appearance callbacks can't be trusted
/// for this — the window has to say.
extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        audioEngine.spectrum.stop()
    }

    /// Also covers minimising and being fully covered by another window, where
    /// the plot is just as invisible as it is when closed.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.occlusionState.contains(.visible) {
            audioEngine.spectrum.start()
        } else {
            audioEngine.spectrum.stop()
        }
    }
}

/// Toolbar for the main window: nothing but the tracking separator that keeps
/// the titlebar's divider aligned with the split.
///
/// The titlebar carries no title or controls — the header at the top of the
/// content column carries them, against the graph they act on. The toolbar stays
/// because the sidebar's full-height layout is defined against it.
///
/// All three methods are implemented because `NSToolbar` treats them as
/// required, whatever Swift's optional conformance suggests: assign a delegate
/// missing `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` and
/// AppKit logs "invalid delegate … does not implement all required methods" and
/// then *discards it* — `toolbar.delegate` reads back nil. The identifiers below
/// are never asked for, no separator is made, and the toolbar the layout is
/// defined against is empty.
extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == .sidebarTrackingSeparator,
            let splitViewController
        else { return nil }

        // Divider zero: the one between the sidebar and the content column.
        return NSTrackingSeparatorToolbarItem(
            identifier: itemIdentifier,
            splitView: splitViewController.splitView,
            dividerIndex: 0
        )
    }
}
