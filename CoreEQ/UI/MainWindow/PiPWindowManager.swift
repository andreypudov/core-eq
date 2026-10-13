import AppKit
import SwiftUI

@MainActor
final class PiPWindowManager: NSObject, NSWindowDelegate {
    static let shared = PiPWindowManager()

    private var window: NSWindow?
    private var host: NSHostingController<Spectrum11BarView>?
    private var analyzer: SpectrumAnalyzer?
    private let defaultSize = NSSize(width: 200, height: 80)
    private let dragStripHeight: CGFloat = 28

    var isVisible: Bool { window != nil }

    func show(analyzer: SpectrumAnalyzer) {
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

        let container = PiPContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let dragStrip = DragStripView(height: dragStripHeight)
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        dragStrip.wantsLayer = true
        dragStrip.layer?.backgroundColor = NSColor.clear.cgColor

        container.addSubview(dragStrip)
        container.addSubview(hosting.view)

        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dragStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dragStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dragStrip.topAnchor.constraint(equalTo: container.topAnchor),
            dragStrip.heightAnchor.constraint(equalToConstant: dragStripHeight),

            hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: dragStrip.bottomAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let newWindow = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 120, y: 120), size: defaultSize),
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        newWindow.contentView = container
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.level = .floating
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newWindow.isMovableByWindowBackground = false // we use custom drag strip
        newWindow.isMovable = true

        newWindow.standardWindowButton(.closeButton)?.isHidden = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true

        newWindow.contentMinSize = NSSize(width: 160, height: 64)
        newWindow.contentMaxSize = NSSize(width: 800, height: 400)

        newWindow.delegate = self
        self.window = newWindow

        // Start analyzer for PiP — SpectrumAnalyzer.start is idempotent and ref-counted
        analyzer.start()

        newWindow.makeKeyAndOrderFront(nil)
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

    func windowWillClose(_ notification: Notification) {
        if let analyzer = analyzer {
            analyzer.stop()
            self.analyzer = nil
        }
        host = nil
        window = nil
    }

    func windowDidMiniaturize(_ notification: Notification) {
        analyzer?.start()
    }
}

final class PiPContainerView: NSView {
    // Let the system handle edge resize; don't intercept mouseDown here.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}

final class DragStripView: NSView {
    private var trackingArea: NSTrackingArea?
    private let dragHeight: CGFloat

    init(height: CGFloat) {
        self.dragHeight = height
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        updateTrackingArea()
    }

    required init?(coder: NSCoder) {
        self.dragHeight = 28
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        updateTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let ta = trackingArea {
            removeTrackingArea(ta)
            trackingArea = nil
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        let ta = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { super.mouseDown(with: event); return }
        // show closed hand while dragging
        NSCursor.closedHand.push()
        win.performDrag(with: event)
        NSCursor.pop() // restore previous cursor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Ensure the strip receives events across its full width
        return self
    }
}
