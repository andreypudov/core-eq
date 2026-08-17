import Foundation
import ServiceManagement
import os

/// Whether CoreEQ opens itself when the user logs in.
///
/// `SMAppService.mainApp` registers the application itself, so there is no helper
/// bundle to build, sign, or keep in step with the app.
///
/// The state deliberately has no stored copy. macOS owns it — the user can revoke
/// it in System Settings → General → Login Items without CoreEQ running, and a
/// remembered `Bool` would then describe a world that no longer exists. Every read
/// asks the system.
enum LoginItem {
    private static let logger = Logger(subsystem: "com.andreypudov.coreeq", category: "LoginItem")

    /// True when macOS will launch CoreEQ at login.
    ///
    /// `.requiresApproval` counts as off: the registration exists but the user has
    /// not approved it, so nothing will launch, and a control claiming otherwise
    /// would be wrong in the one direction that matters.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turns the login item on or off, returning whether the system agreed.
    ///
    /// A refusal is reported rather than swallowed: the caller has a control
    /// showing a state, and it must go back to what the system actually says.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return isEnabled == enabled
        } catch {
            logger.error(
                "Login item \(enabled ? "registration" : "removal", privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
