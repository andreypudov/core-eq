import AppKit
import SwiftUI

@MainActor
final class PiPWindowManager: NSObject, NSWindowDelegate {
    static let shared = PiPWindowManager()

    private var window: NSWindow?
    private var host: NSHostingController<Spectrum11BarView>?
    private var analyzer: SpectrumAnalyzer?
    private let defaultSize = NSSize(width: 200, height: 80)
    private let dragStripHeight: CGFloat = 20

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

        let dragStrip = DragStripView()
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
        newWindow.isMovableByWindowBackground = true
        newWindow.isMovable = true

        newWindow.standardWindowButton(.closeButton)?.isHidden = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true

        newWindow.contentMinSize = NSSize(width: 160, height: 64)
        newWindow.contentMaxSize = NSSize(width: 800, height: 400)

        newWindow.delegate = self
        self.window = newWindow

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
    override func mouseDown(with event: NSEvent) {
        // Let resize continue on edges; only the dedicated drag strip owns window movement.
        // This allows the window to still resize from corners/borders while the top strip moves it.
        super.mouseDown(with: event)
    }
}

final class DragStripView: NSView {
    override func mouseDown(with event: NSEvent) {
        if let win = self.window {
            win.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}
