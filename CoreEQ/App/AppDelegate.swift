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
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(
            profileManager: profileManager,
            audioEngine: audioEngine,
            outputs: outputs,
            openMainWindow: { [weak self] in self?.showMainWindow() },
            showAbout: { [weak self] in self?.showAbout() }
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
            // Header, editing area, and padding come to ~380 pt; the rest is the
            // graph, which has a 120 pt floor.
            window.contentMinSize = NSSize(width: 960, height: 540)
            let visible = (NSScreen.main?.visibleFrame.size).map {
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

    /// The system's own About panel rather than a window of our own: it already
    /// knows how to lay out an icon, a name, a version and a copyright line, and
    /// it reads all four out of the bundle, so there is nothing here to keep in
    /// step with the build.
    ///
    /// Activated first for the same reason the settings window is — an accessory
    /// application is not frontmost when its menu is clicked, and the panel would
    /// otherwise open behind whatever is.
    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CoreEQ",
            // The panel shows the marketing version and then the build in
            // parentheses — "Version 1.6 (7)". The build number means something
            // to the release pipeline and nothing to the person reading it, and
            // an empty string is the documented way to leave it out.
            // `CFBundleShortVersionString` still supplies the 1.6.
            .version: "",
            .credits: Self.aboutCredits,
        ])
    }

    /// The panel's info area: one sentence about what CoreEQ is, then the two
    /// places worth going.
    ///
    /// Everything here is measured against the panel's own metrics rather than
    /// guessed: the text column is 268 points wide, so the sentence is written to
    /// fall on two lines and the links share a third. Longer copy scrolls, and a
    /// scrollbar inside a 284-point panel looks like a mistake.
    ///
    /// The copyright and licence sit below the version, from
    /// `NSHumanReadableCopyright` in the bundle — the place the system reserves
    /// for them — so this text does not repeat either.
    private static var aboutCredits: NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: "Equalizes everything you hear, with no driver and nothing left behind.\n\n",
            attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]
        )
        credits.append(link("Source code", to: "https://github.com/andreypudov/core-eq", font: body))
        credits.append(NSAttributedString(
            string: "  ·  ",
            attributes: [.font: body, .foregroundColor: NSColor.tertiaryLabelColor]
        ))
        // The release list rather than this version's tag: a tag exists only once
        // the release is cut, so a build made between releases would send the
        // user to a 404. The list always resolves, newest first.
        credits.append(link("Release notes", to: "https://github.com/andreypudov/core-eq/releases", font: body))

        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        credits.addAttribute(
            .paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length)
        )
        return credits
    }

    private static func link(_ text: String, to urlString: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: font, .link: URL(string: urlString) as Any]
        )
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
