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

extension View {
    /// Mounts `label` on the block's top border, cutting the stroke the way a tab
    /// view's tabs and a titled box's title do.
    ///
    /// The label carries the window's own material rather than a colour, because
    /// the surface behind the border is a vibrant `NSVisualEffectView` and a flat
    /// fill reads as a patch over it rather than a gap in the stroke.
    ///
    /// `alignment` places it: `.top` for the editor's tabs, `.topLeading` for the
    /// trim's title.
    func borderLabel<Label: View>(
        alignment: Alignment = .top,
        @ViewBuilder _ label: () -> Label
    ) -> some View {
        overlay(alignment: alignment) {
            label()
                .padding(.horizontal, 8)
                .frame(height: Theme.borderLabelHeight)
                .background(WindowBackground())
                .padding(.horizontal, alignment == .top ? 0 : Theme.blockPadding)
                .offset(y: -Theme.borderLabelHeight / 2)
        }
    }
}
