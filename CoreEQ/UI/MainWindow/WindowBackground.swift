import AppKit
import SwiftUI

/// The window's own background material, for the content column to sit on.
///
/// A flat `Color(nsColor: .windowBackgroundColor)` fill is not the same surface:
/// the titlebar and the sidebar are both vibrant materials, and against them the
/// solid colour reads markedly darker, so the column looked like a sunken well
/// rather than the page the blocks rest on. Taking the real material makes the
/// three continuous.
struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
