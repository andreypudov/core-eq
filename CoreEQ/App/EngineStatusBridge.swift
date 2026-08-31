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

    /// What the engine settled on, for the Diagnostics pane. Nil when it is not
    /// running, which the report says rather than hides.
    @Published private(set) var diagnostics: DiagnosticsReport.Engine?

    /// What the engine observed about the system audio permission, which is not
    /// the same question as whether it is running.
    @Published private(set) var tapAccess: TapAccess = .unknown

    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    /// Called once, by whoever owns the engine.
    func follow(_ engine: AudioEngine) {
        engine.$status
            .sink { [weak self] status in self?.status = status }
            .store(in: &cancellables)
        engine.$diagnostics
            .sink { [weak self] diagnostics in self?.diagnostics = diagnostics }
            .store(in: &cancellables)
        engine.$tapAccess
            .sink { [weak self] access in self?.tapAccess = access }
            .store(in: &cancellables)
    }
}
