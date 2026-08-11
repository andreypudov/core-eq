import AppKit
import SwiftUI

/// Makes a control adjustable by scroll wheel and trackpad.
///
/// AppKit's own sliders don't do this, but every equalizer a knowledgeable user
/// has met does, and it is the only way to land on an exact value in a 26 pt
/// column without a careful drag. It adds no chrome and costs nothing to anyone
/// who never tries it.
///
/// The parametric band knobs and their number fields carry it too, even though
/// their rows live in a `ScrollView`. Both are small, deliberate targets: a
/// scroll that starts over one is aimed at that value, and every other point in
/// the row still scrolls the list.
struct ScrollAdjuster: NSViewRepresentable {
    let isEnabled: Bool
    /// Scroll distance that makes one step.
    let pointsPerStep: CGFloat
    /// Called with a signed step count once enough scroll has accumulated.
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: CatcherView) {
        view.isEnabled = isEnabled
        view.pointsPerStep = pointsPerStep
        view.onStep = onStep
    }

    final class CatcherView: NSView {
        var onStep: ((Int) -> Void)?
        var pointsPerStep: CGFloat = 6
        var isEnabled = true

        /// Scroll left over from the last event, held until it makes a whole
        /// step. Precise trackpad deltas arrive as fractions of a point, so
        /// applying them directly would make the value jitter instead of
        /// clicking through the same detents a drag uses.
        private var accumulated: CGFloat = 0

        /// Visible to scroll events and invisible to every other kind, so the
        /// control underneath keeps its drag, its double-click, and its hover.
        /// `NSApp.currentEvent` during hit testing is the event being routed.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard isEnabled, NSApp.currentEvent?.type == .scrollWheel else { return nil }
            return self
        }

        override func scrollWheel(with event: NSEvent) {
            guard isEnabled else { return super.scrollWheel(with: event) }
            // Momentum is the tail of a flick, arriving after the fingers have
            // lifted. Acting on it keeps the value moving when the gesture is
            // over, which reads as the control running away.
            guard event.momentumPhase == [] else { return }

            // Normalised against the "natural scrolling" setting so the physical
            // gesture means the same either way: wheel away from you, or fingers
            // up, increases.
            let inverted = event.isDirectionInvertedFromDevice
            let dy = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
            let dx = inverted ? -event.scrollingDeltaX : event.scrollingDeltaX
            let delta = abs(dy) >= abs(dx) ? dy : dx
            guard delta != 0 else { return }

            // Precise deltas are points; a notched wheel reports lines, and one
            // line should be one step.
            accumulated += event.hasPreciseScrollingDeltas ? delta : delta * pointsPerStep

            let steps = Int((accumulated / pointsPerStep).rounded(.towardZero))
            guard steps != 0 else { return }
            accumulated -= CGFloat(steps) * pointsPerStep
            onStep?(steps)
        }
    }
}

extension View {
    /// Adjusts this control by scroll wheel or trackpad. See `ScrollAdjuster`.
    func scrollAdjustable(
        isEnabled: Bool = true,
        pointsPerStep: CGFloat = 6,
        onStep: @escaping (Int) -> Void
    ) -> some View {
        overlay(ScrollAdjuster(isEnabled: isEnabled, pointsPerStep: pointsPerStep, onStep: onStep))
    }
}
