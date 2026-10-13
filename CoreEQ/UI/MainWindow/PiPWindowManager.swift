@MainActor
import AppKit
import SwiftUI

@MainActor
final class PiPWindowManager {
    static let shared = PiPWindowManager()

    private var window: NSWindow?
    private var analyzer: SpectrumAnalyzer?
    private let defaultSize = NSSize(width: 200, height: 80)

    func show(analyzer: SpectrumAnalyzer) {
        // Ensure any existing window is closed and its analyzer stopped.
        hide()

        self.analyzer = analyzer

        let host = NSHostingController(rootView: Spectrum11BarView(analyzer: analyzer))
        let newWindow = NSWindow(contentViewController: host)

        // Use a transparent titlebar but keep the window titled/resizable so
        // it supports dragging by background and system resize handles.
        newWindow.styleMask = [.titled, .fullSizeContentView, .resizable]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden

        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.level = .floating
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Allow dragging by background for a borderless look.
        newWindow.isMovableByWindowBackground = true
        newWindow.isMovable = true

        // Hide standard titlebar controls if desired (keeps a cleaner PiP look)
        newWindow.standardWindowButton(.closeButton)?.isHidden = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true

        newWindow.setFrame(
            CGRect(origin: CGPoint(x: 120, y: 120), size: defaultSize),
            display: true
        )
        newWindow.isReleasedWhenClosed = true

        self.window = newWindow

        // Start analyzer explicitly for PiP so it remains live even if the
        // main window is closed or hidden.
        analyzer.start()

        newWindow.makeKeyAndOrderFront(nil)
    }

    func hide() {
        // Stop the analyzer when PiP is explicitly closed.
        if let analyzer = analyzer {
            analyzer.stop()
            self.analyzer = nil
        }

        window?.close()
        window = nil
    }
}
