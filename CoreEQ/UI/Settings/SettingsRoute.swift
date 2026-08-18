import Foundation

/// The Settings window's two panes.
enum SettingsTab: Hashable {
    case general
    case about
}

/// Which pane the Settings window should show.
///
/// A scene cannot be handed an argument, so the destination is put here before
/// the window is asked to open. It is not persisted: the gear means General and
/// the app mark means About, every time, rather than "wherever you were last".
@MainActor
final class SettingsRoute: ObservableObject {
    static let shared = SettingsRoute()

    @Published var tab: SettingsTab = .general

    private init() {}
}
