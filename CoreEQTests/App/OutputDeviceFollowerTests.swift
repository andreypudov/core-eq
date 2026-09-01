import Combine
import Testing

/// Following the system's output device.
///
/// Two bugs lived in this subscription and neither was visible as a failure:
/// the user's edits came back attached to the wrong output, a launch or two
/// later. Both are stated here as rules.
@MainActor
struct OutputDeviceFollowerTests {

    /// A source that emits the way `@Published` does — in `willSet`, so
    /// `current` still holds the *previous* value while subscribers run.
    ///
    /// This is the whole shape of the original bug. Anything reading the source
    /// back during delivery gets the device being replaced.
    private final class WillSetSource {
        private let subject = PassthroughSubject<String?, Never>()
        private(set) var current: String?

        var publisher: AnyPublisher<String?, Never> { subject.eraseToAnyPublisher() }

        func change(to uid: String?) {
            subject.send(uid)
            current = uid
        }
    }

    private func makeFollower(
        _ source: WillSetSource,
        note: @escaping @MainActor (String?) -> Void = { _ in },
        adopt: @escaping @MainActor (String?) -> Void
    ) -> AnyCancellable {
        OutputDeviceFollower.follow(source.publisher, note: note, adopt: adopt)
    }

    // MARK: - The device that is adopted

    /// The rule that was broken: what arrives is what is adopted.
    ///
    /// The source deliberately reads back as the previous device throughout
    /// delivery, so a follower that consulted it instead of using the value it
    /// was handed would file the user's sound under the output they just left.
    @Test func theDeviceAdoptedIsTheOneJustReported() {
        let source = WillSetSource()
        var adopted: [String?] = []
        var seenAsCurrent: [String?] = []

        let following = makeFollower(source) { uid in
            adopted.append(uid)
            seenAsCurrent.append(source.current)
        }

        source.change(to: "BuiltInSpeakerDevice")
        source.change(to: "BlackHole16ch")

        #expect(adopted == ["BuiltInSpeakerDevice", "BlackHole16ch"])
        #expect(
            seenAsCurrent == [nil, "BuiltInSpeakerDevice"],
            "the source did not lag; this test no longer reproduces the bug it guards")
        following.cancel()
    }

    /// Losing the output is a change like any other. Pulling a jack reports nil
    /// before the fallback appears, and the follower's job is to pass it on —
    /// deciding to hold still through the gap belongs to `ProfileManager`, which
    /// is where it can tell a gap from a real absence.
    @Test func theAbsenceOfADeviceIsReported() {
        let source = WillSetSource()
        var adopted: [String?] = []

        let following = makeFollower(source) { adopted.append($0) }
        source.change(to: "BuiltInSpeakerDevice")
        source.change(to: nil)

        #expect(adopted == ["BuiltInSpeakerDevice", nil])
        following.cancel()
    }

    // MARK: - Repeats

    /// Every hardware event refreshes the whole list and republishes the same
    /// UID. Acting on each one would persist and reload the device's state
    /// dozens of times a session for no change at all.
    @Test func theSameDeviceReportedTwiceIsAdoptedOnce() {
        let source = WillSetSource()
        var adopted: [String?] = []

        let following = makeFollower(source) { adopted.append($0) }
        source.change(to: "BuiltInSpeakerDevice")
        source.change(to: "BuiltInSpeakerDevice")
        source.change(to: "BuiltInSpeakerDevice")

        #expect(adopted == ["BuiltInSpeakerDevice"])
        following.cancel()
    }

    /// Dropping repeats must not mean dropping a return. Switching away and
    /// back is an ordinary thing to do with a pair of headphones.
    @Test func aDeviceReturnedToIsAdoptedAgain() {
        let source = WillSetSource()
        var adopted: [String?] = []

        let following = makeFollower(source) { adopted.append($0) }
        source.change(to: "BuiltInSpeakerDevice")
        source.change(to: "BlackHole16ch")
        source.change(to: "BuiltInSpeakerDevice")

        #expect(adopted == ["BuiltInSpeakerDevice", "BlackHole16ch", "BuiltInSpeakerDevice"])
        following.cancel()
    }

    // MARK: - Diagnostics

    /// Both halves see the same device. A report exists to show where the two
    /// disagree, and it can only do that if nothing here introduces a
    /// disagreement of its own.
    @Test func theObservationRecordedIsTheDeviceAdopted() {
        let source = WillSetSource()
        var noted: [String?] = []
        var adopted: [String?] = []

        let following = makeFollower(
            source,
            note: { noted.append($0) },
            adopt: { adopted.append($0) })
        source.change(to: "BlackHole16ch")

        #expect(noted == adopted)
        following.cancel()
    }

    /// Recorded before adopted, so a failure while adopting still leaves
    /// evidence that the change arrived — which is the fact that separates "the
    /// list never noticed" from "the EQ never followed".
    @Test func theObservationIsRecordedBeforeItIsActedOn() {
        let source = WillSetSource()
        var order: [String] = []

        let following = makeFollower(
            source,
            note: { _ in order.append("note") },
            adopt: { _ in order.append("adopt") })
        source.change(to: "BlackHole16ch")

        #expect(order == ["note", "adopt"])
        following.cancel()
    }

    // MARK: - Lifetime

    /// The subscription belongs to whoever holds it. The app delegate holds it
    /// for the life of the process; a released one must stop.
    @Test func aCancelledFollowerStopsFollowing() {
        let source = WillSetSource()
        var adopted: [String?] = []

        let following = makeFollower(source) { adopted.append($0) }
        source.change(to: "BuiltInSpeakerDevice")
        following.cancel()
        source.change(to: "BlackHole16ch")

        #expect(adopted == ["BuiltInSpeakerDevice"])
    }
}
