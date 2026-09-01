import AppKit
import Testing

/// The scroll handling behind every knob, field, and band slider.
///
/// Its whole job is turning a stream of wheel and trackpad deltas into whole
/// detents, and the failure modes are the ones a user notices immediately: a
/// value that runs away after the fingers lift, one that jitters on a precise
/// trackpad, or one that scrolls the wrong way on a Mac set to natural
/// scrolling.
@MainActor
@Suite(.serialized)
struct ScrollAdjusterTests {
    private func makeCatcher(
        pointsPerStep: CGFloat = 6
    ) -> (ScrollAdjuster.CatcherView, () -> [Int]) {
        let view = ScrollAdjuster.CatcherView()
        view.pointsPerStep = pointsPerStep
        view.isEnabled = true

        var steps: [Int] = []
        view.onStep = { steps.append($0) }
        return (view, { steps })
    }

    /// A notched mouse wheel reports lines, and one line is one detent.
    private func wheelEvent(lines: Int32) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: lines, wheel2: 0, wheel3: 0
        )!
        return NSEvent(cgEvent: cg)!
    }

    /// A trackpad reports points, often fractions of one at a time.
    private func trackpadEvent(points: Int32) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: points, wheel2: 0, wheel3: 0
        )!
        return NSEvent(cgEvent: cg)!
    }

    // MARK: - Detents

    @Test func oneWheelLineIsOneDetent() {
        let (view, steps) = makeCatcher()

        view.scrollWheel(with: wheelEvent(lines: 1))
        #expect(steps() == [1])

        view.scrollWheel(with: wheelEvent(lines: -1))
        #expect(steps() == [1, -1])
    }

    /// Precise deltas arrive as small numbers of points. Applying them directly
    /// would make the value jitter instead of clicking through the same detents
    /// a drag uses, so they accumulate until they make a whole one.
    @Test func smallTrackpadDeltasAccumulateIntoOneDetent() {
        let (view, steps) = makeCatcher(pointsPerStep: 6)

        for _ in 0..<5 { view.scrollWheel(with: trackpadEvent(points: 1)) }
        #expect(steps() == [], "five points of a six point detent moved the value")

        view.scrollWheel(with: trackpadEvent(points: 1))
        #expect(steps() == [1], "the sixth point should have completed the detent")
    }

    /// The leftover is kept, not discarded — otherwise a slow scroll would lose
    /// a fraction of a detent on every event and never arrive.
    @Test func theRemainderCarriesToTheNextEvent() {
        let (view, steps) = makeCatcher(pointsPerStep: 6)

        view.scrollWheel(with: trackpadEvent(points: 8))
        #expect(steps() == [1])

        // 2 points were left over, so 4 more make the next detent.
        view.scrollWheel(with: trackpadEvent(points: 4))
        #expect(steps() == [1, 1])
    }

    @Test func aFlickDeliversSeveralDetentsAtOnce() {
        let (view, steps) = makeCatcher(pointsPerStep: 6)

        view.scrollWheel(with: trackpadEvent(points: 30))
        #expect(steps() == [5])
    }

    /// Scrolling back the way you came has to undo what it did, or every
    /// control drifts. This is the same property the value ladders guarantee,
    /// one layer down.
    @Test func scrollingBackUndoesTheSameNumberOfDetents() {
        let (view, steps) = makeCatcher(pointsPerStep: 6)

        view.scrollWheel(with: trackpadEvent(points: 18))
        view.scrollWheel(with: trackpadEvent(points: -18))
        #expect(steps().reduce(0, +) == 0, "a scroll and its reverse did not cancel")
    }

    // MARK: - What it refuses

    /// Momentum is the tail of a flick, arriving after the fingers have lifted.
    /// Acting on it keeps the value moving when the gesture is over, which
    /// reads as the control running away on its own.
    @Test func momentumIsIgnored() throws {
        let (view, steps) = makeCatcher()
        let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: 60, wheel2: 0, wheel3: 0
        )!
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)  // .changed
        let momentum = try #require(NSEvent(cgEvent: cg))
        #expect(momentum.momentumPhase != [], "the event is not carrying momentum")

        view.scrollWheel(with: momentum)
        #expect(steps() == [], "the value kept moving after the fingers lifted")
    }

    @Test func aDisabledCatcherIgnoresScrolling() {
        let (view, steps) = makeCatcher()
        view.isEnabled = false

        view.scrollWheel(with: wheelEvent(lines: 3))
        #expect(steps() == [])
    }

    /// The catcher is visible to scroll events and invisible to every other
    /// kind, so the control underneath keeps its drag, its double-click, and
    /// its hover.
    @Test func itIsInvisibleToEverythingButScrolling() {
        // `hitTest` asks `NSApp` which event is being routed, and `NSApp` stays
        // nil until an application exists. In the app one always does; here it
        // has to be asked for — and only this test needs it, so the rest of the
        // suite stays headless.
        _ = NSApplication.shared

        let (view, _) = makeCatcher()
        #expect(
            view.hitTest(NSPoint(x: 1, y: 1)) == nil,
            "with no scroll event in flight the catcher must not take the click")
    }
}
