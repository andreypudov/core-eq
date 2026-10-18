import Foundation

/// The AutoEq catalog's state, where the Settings scene can see it.
///
/// The same boundary `EngineStatusBridge` and `ProfileStatusBridge` cross: the
/// store is owned by the app delegate, and the Settings window is a separate
/// scene that cannot be handed it. Asked when the diagnostics report is drawn
/// rather than published, because nothing on screen follows it.
@MainActor
final class AutoEQStatusBridge {
    static let shared = AutoEQStatusBridge()

    private weak var store: AutoEQStore?

    private init() {}

    /// Called once, by whoever owns the store.
    func follow(_ store: AutoEQStore) {
        self.store = store
    }

    /// The catalog's section of the diagnostics report, or nil before the
    /// store exists.
    var diagnostics: DiagnosticsReport.AutoEQ? { store?.diagnostics() }
}
