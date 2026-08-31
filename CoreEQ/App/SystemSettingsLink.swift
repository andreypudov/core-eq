import AppKit

/// Opens the System Settings pane where capturing system audio is allowed.
///
/// The only thing that can change a refusal. macOS raises its permission
/// prompt once; after that the answer is recorded and asking again does
/// nothing, so an app that offers to try again is offering something it cannot
/// deliver — the way through is this pane.
enum SystemSettingsLink {
    /// Privacy & Security → Screen & System Audio Recording, which is where
    /// capturing system audio is listed even though CoreEQ never records a
    /// screen.
    static func openAudioCapturePrivacy() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }
}
