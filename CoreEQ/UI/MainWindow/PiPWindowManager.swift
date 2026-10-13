import AppKit
import SwiftUI

@MainActor
final class PiPWindowManager {
    static let shared = PiPWindowManager()

    private var window: NSWindow?
    private var analyzer: SpectrumAnalyzer?
    private let defaultSize = NSSize(width: 200, height: 80)

    var isVisible: Bool { window != nil }

    func show(analyzer: SpectrumAnalyzer) {
        hide()

        self.analyzer = analyzer

        let host = NSHostingController(rootView: Spectrum11BarView(analyzer: analyzer))
        let newWindow = NSWindow(contentViewController: host)

        newWindow.styleMask = [.titled, .fullSizeContentView, .resizable]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden

        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.level = .floating
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        newWindow.isMovableByWindowBackground = true
        newWindow.isMovable = true

        newWindow.standardWindowButton(.closeButton)?.isHidden = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true

        newWindow.setFrame(
            CGRect(origin: CGPoint(x: 120, y: 120), size: defaultSize),
            display: true
        )
        newWindow.isReleasedWhenClosed = true

        self.window = newWindow

        analyzer.start()

        newWindow.makeKeyAndOrderFront(nil)
    }

    func hide() {
        if let analyzer = analyzer {
            analyzer.stop()
            self.analyzer = nil
        }
        window?.close()
        window = nil
    }
}
