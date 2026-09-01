import Combine
import Foundation

/// What the profile manager currently holds, where the Settings scene can see
/// it.
///
/// The same boundary `EngineStatusBridge` crosses, for the same reason: Settings
/// is a separate scene and cannot be handed the manager.
///
/// It carries the *live* state deliberately. The diagnostics report could
/// already read what is filed in `SettingsStore`, and that turned out to be the
/// less useful half — when a preset comes back wrong, the stored slot is
/// usually right and the disagreement is with what ended up on screen. Reporting
/// only one side cannot show that, so this supplies the other.
@MainActor
final class ProfileStatusBridge: ObservableObject {
    static let shared = ProfileStatusBridge()

    @Published private(set) var activeProfileName: String?
    @Published private(set) var abSlot: ABSlot?
    @Published private(set) var outputDeviceUID: String?

    /// What `AudioDeviceList` last reported, and how many changes it has
    /// reported. The manager only learns of a device change through that list,
    /// so a count stuck at 1 while the system default has moved says the list
    /// never noticed — which is a different fault from the manager ignoring it.
    ///
    /// Repeats are already dropped upstream by `OutputDeviceFollower`, so this
    /// counts distinct outputs seen, not property notifications received. Every
    /// hardware event republishes the same UID, and a number that climbed on its
    /// own would answer nothing.
    @Published private(set) var deviceListUID: String?
    @Published private(set) var deviceListUpdates = 0

    private var cancellables: Set<AnyCancellable> = []

    /// The app uses `shared`. A fresh instance exists so the counting rule can
    /// be exercised without one test's device changes being visible to the next.
    init() {}

    /// Called by whoever owns the device list, on every change it reports.
    func noteDeviceList(uid: String?) {
        deviceListUID = uid
        deviceListUpdates += 1
    }

    /// Called once, by whoever owns the manager.
    func follow(_ manager: ProfileManager) {
        manager.$activeProfileName
            .sink { [weak self] name in
                self?.activeProfileName = name
                // Read rather than published: it changes with the device, and
                // every device change also republishes the profile name.
                self?.outputDeviceUID = manager.outputDeviceUID
            }
            .store(in: &cancellables)

        manager.$abSlot
            .sink { [weak self] slot in self?.abSlot = slot }
            .store(in: &cancellables)
    }
}
