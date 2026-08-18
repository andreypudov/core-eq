import Combine
import Foundation

/// The engine's status, where the Settings scene can see it.
///
/// `AudioEngine` is owned by the app delegate and created lazily; the Settings
/// window is a separate scene that SwiftUI builds on its own schedule, so it
/// cannot be handed the engine. This carries the one fact that window needs
/// across that boundary, and nothing else.
@MainActor
final class EngineStatusBridge: ObservableObject {
    static let shared = EngineStatusBridge()

    @Published private(set) var status: AudioEngine.Status = .stopped

    private var cancellable: AnyCancellable?

    private init() {}

    /// Called once, by whoever owns the engine.
    func follow(_ engine: AudioEngine) {
        cancellable = engine.$status.sink { [weak self] status in
            self?.status = status
        }
    }
}
