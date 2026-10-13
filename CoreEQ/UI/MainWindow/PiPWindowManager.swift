import AppKit
import SwiftUI

@MainActor
final class PiPWindowManager: NSObject, NSWindowDelegate {
    static let shared = PiPWindowManager()

    private var window: NSWindow?
    private var host: NSHostingController<Spectrum11BarView>?
    private var analyzer: SpectrumAnalyzer?
    private let defaultSize = NSSize(width: 200, height: 80)

    var isVisible: Bool { window != nil }

    func show(analyzer: SpectrumAnalyzer) {
        // Ensure this runs on the main actor
        hideIfNeededBeforeShow()

        // If already visible, just update the analyzer/view
        if let existingHost = host, window != nil {
            self.analyzer = analyzer
            existingHost.rootView = Spectrum11BarView(analyzer: analyzer)
            return
        }

        self.analyzer = analyzer

        let root = Spectrum11BarView(analyzer: analyzer)
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        self.host = hosting

        // Container that intercepts mouseDown for window dragging
        let container = DraggingContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Add hosting view into container
        container.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let newWindow = NSWindow(contentRect: CGRect(origin: CGPoint(x: 120, y: 120), size: defaultSize),
                                 styleMask: [.titled, .fullSizeContentView, .resizable],
                                 backing: .buffered,
                                 defer: false)

        newWindow.contentView = container
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden

        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.level = .floating
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Allow dragging by background (and container will forward events)
        newWindow.isMovableByWindowBackground = true
        newWindow.isMovable = true

        // Keep system buttons hidden for PiP look but leave them functional
        newWindow.standardWindowButton(.closeButton)?.isHidden = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true

        newWindow.delegate = self

        // Manage lifecycle explicitly: do NOT use isReleasedWhenClosed
        self.window = newWindow

        // Start analyzer for PiP — SpectrumAnalyzer.start is idempotent
        analyzer.start()

        newWindow.makeKeyAndOrderFront(nil)
    }

    private func hideIfNeededBeforeShow() {
        // If an existing window exists but has been closed, ensure cleanup
        if window == nil { return }
    }

    func hide() {
        Task { @MainActor in
            if let analyzer = analyzer {
                analyzer.stop()
                self.analyzer = nil
            }
            host = nil
            window?.orderOut(nil)
            window = nil
        }
    }

    // NSWindowDelegate: ensure cleanup when the window is closed by the system
    func windowWillClose(_ notification: Notification) {
        // stop analyzer and drop references
        if let analyzer = analyzer {
            analyzer.stop()
            self.analyzer = nil
        }
        host = nil
        window = nil
    }

    // Keep analyzer running while window is miniaturized — don't stop it here
    func windowWillMiniaturize(_ notification: Notification) {
        // intentionally left blank to keep analyzer running
    }

    func windowDidMiniaturize(_ notification: Notification) {
        // ensure analyzer is running (defensive)
        analyzer?.start()
    }
}

/// Small NSView that forwards mouse down events to the window's drag handler
final class DraggingContainerView: NSView {
    override func mouseDown(with event: NSEvent) {
        // Let window perform window drag; if that's not available fallback to
        // super.mouseDown which lets subviews handle the event.
        if let win = self.window {
            win.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    // Allow the view to be transparent to hit testing for controls inside it
    override func hitTest(_ point: NSPoint) -> NSView? {
        // If a subview wants the event, let it handle; otherwise return self
        if let sub = super.hitTest(point), sub !== self {
            return sub
        }
        return self
    }
}
