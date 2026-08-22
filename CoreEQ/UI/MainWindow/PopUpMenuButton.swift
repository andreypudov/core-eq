import AppKit
import SwiftUI

/// A button that opens a real `NSMenu`.
///
/// SwiftUI's `Menu` draws only the first `Text` of whatever label it is given —
/// `.borderlessButton`, `.button`, and the default style alike — so a label with
/// a second line silently loses it. Overlaying a clear-labelled `Menu` on top of
/// a hand-drawn label keeps the drawing but not the control: the popup button
/// underneath collapses to 11 × 14 points no matter what frame or content shape
/// it is given, and the click lands nowhere.
///
/// A `Button` puts no such limit on its label. So the label is SwiftUI's, drawn
/// in full, and the menu is AppKit's. The anchor view is invisible and exists
/// only to give `NSMenu` something to position itself against.
struct PopUpMenuButton<Label: View>: View {
    let menu: () -> NSMenu
    @ViewBuilder let label: () -> Label

    @State private var anchor = MenuAnchorBox()
    @State private var isHovering = false

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            // Below the control, the way a pop-up button drops its list.
            let origin = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
            menu().popUp(positioning: nil, at: origin, in: view)
        } label: {
            label()
                // Both of these are inside the label on purpose. A button's hit
                // area is whatever its label actually draws, so a label made of
                // text, a `Spacer` and a small glyph is clickable only on the
                // ink: measured, clicks landed in the spacer and beside the
                // chevron and did nothing. Filling the width and taking a
                // rectangular content shape makes the whole control the target.
                // Applied outside the button instead, neither has any effect.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(box: anchor))
        // A borderless pop-up says it is one by lighting up under the pointer.
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// An `NSMenuItem` that runs a closure, so a menu can be built from SwiftUI
/// where there is no object to be the target of an action.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        handler()
    }
}

@MainActor
final class MenuAnchorBox {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let box: MenuAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}
