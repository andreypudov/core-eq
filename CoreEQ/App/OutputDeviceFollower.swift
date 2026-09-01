import Combine
import Foundation

/// Keeping the EQ pointed at the output device the system is actually using.
///
/// Each output keeps its own preset, edits, trim, and tone — the way macOS keeps
/// a volume per device — so every device change moves where the user's work is
/// filed. Getting it wrong does not look like a crash: it looks like a preset
/// that quietly came back wrong on the next launch.
///
/// It went wrong twice, both times at the subscription rather than in anything
/// this calls, which is why the rule lives here as its own named thing:
///
/// - The value has to be the **emitted** one. `@Published` emits in `willSet`,
///   so a subscriber that reaches back into the device list instead of using
///   what it was handed reads the device being *replaced*, and files the user's
///   edits under the output they just left. The signature is the guard: nothing
///   is passed in that could be re-read, so the mistake cannot be written here.
/// - Repeats have to be dropped. Every hardware event refreshes the whole list
///   and republishes the UID, unchanged, many times a session.
///
/// The observation is recorded before it is adopted, so a report drawn after a
/// failure still shows that the change arrived — the question a report has to
/// settle is whether the list never noticed or the EQ never followed, and those
/// have different fixes.
@MainActor
enum OutputDeviceFollower {

    /// Follows `deviceUIDs` until the returned cancellable is released.
    ///
    /// - Parameters:
    ///   - deviceUIDs: what the device list reports, including nil for no
    ///     device. Must emit on the main actor, as `AudioDeviceList` does.
    ///   - note: records the observation for diagnostics.
    ///   - adopt: moves the EQ onto the device.
    /// - Returns: the subscription. Following stops when it is released, so the
    ///   caller has to keep it for as long as the EQ should track the hardware.
    static func follow(
        _ deviceUIDs: some Publisher<String?, Never>,
        note: @escaping @MainActor (String?) -> Void,
        adopt: @escaping @MainActor (String?) -> Void
    ) -> AnyCancellable {
        deviceUIDs
            .removeDuplicates()
            .sink { uid in
                MainActor.assumeIsolated {
                    note(uid)
                    adopt(uid)
                }
            }
    }
}
