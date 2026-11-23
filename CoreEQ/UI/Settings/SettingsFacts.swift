import SwiftUI

/// What the settings panes read from the machine: where settings are stored,
/// whether CoreEQ opens at login, its version, and the diagnostics report.
///
/// The app never sets it, and every pane reads the real thing. It exists so the
/// snapshot tests can draw the panes from fixed facts — they run hosted in the
/// app, under its bundle identifier, where `UserDefaults.standard` is the
/// user's own CoreEQ settings and the login item is the user's own.
///
/// `@unchecked` for `UserDefaults`, which Foundation documents as safe to use
/// from any thread but this SDK does not mark `Sendable`.
struct SettingsFacts: @unchecked Sendable {
    /// Where settings are read and written.
    var defaults: UserDefaults = .standard

    /// Whether macOS will open CoreEQ at login. Nil asks the system.
    var opensAtLogin: Bool?

    /// The version About shows. Nil reads the bundle.
    var appVersion: String?

    /// The report Diagnostics shows. Nil builds it from the running engine.
    var diagnosticsReport: String?

    static let live = SettingsFacts()

    @MainActor var settings: SettingsStore { SettingsStore(defaults: defaults) }

    var isLoginItemEnabled: Bool { opensAtLogin ?? LoginItem.isEnabled }
}

extension EnvironmentValues {
    @Entry var settingsFacts: SettingsFacts = .live
}
