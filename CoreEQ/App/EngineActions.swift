import Foundation

/// The few things a detached scene can ask the engine to do.
///
/// The Settings window is a separate scene and cannot be handed the engine —
/// the same boundary `EngineStatusBridge` carries facts across, in the other
/// direction. That bridge publishes what the engine knows; this one forwards
/// the small number of requests a pane has to make of it.
@MainActor
final class EngineActions {
    static let shared = EngineActions()

    private weak var engine: AudioEngine?

    private init() {}

    /// Called once, by whoever owns the engine.
    func follow(_ engine: AudioEngine) {
        self.engine = engine
    }

    /// Let macOS raise its permission prompt, having explained beforehand what
    /// the permission is for.
    func requestPermission() {
        engine?.requestPermission()
    }
}
