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

        let container = DraggingContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
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

final class DraggingContainerView: NSView {
    override func mouseDown(with event: NSEvent) {
        if let win = self.window {
            win.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let sub = super.hitTest(point) {
            if sub == self.subviews.first {
                return self
            }
            return sub
        }
        return self
    }
}
