import AppKit
import SwiftUI

final class PiPWindowManager {
    static let shared = PiPWindowManager()

    private var window: NSWindow?
    private let defaultSize = NSSize(width: 200, height: 80)

    func show(_ view: some View) {
        hide()

        let host = NSHostingController(rootView: AnyView(view))
        let newWindow = NSWindow(contentViewController: host)

        newWindow.styleMask = [.borderless]
        newWindow.titlebarAppearsTransparent = true
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.level = .floating
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newWindow.setFrame(
            CGRect(origin: CGPoint(x: 120, y: 120), size: defaultSize),
            display: true
        )
        newWindow.isReleasedWhenClosed = true

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.close()
        window = nil
    }
}

