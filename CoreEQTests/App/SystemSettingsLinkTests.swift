import Foundation
import Testing

/// The link out to System Settings.
///
/// macOS raises its permission prompt once; after that the answer is recorded
/// and asking again does nothing, so this pane is the only way a user who
/// refused can change their mind. A malformed URL fails silently — the button
/// does nothing and reports nothing — which is why the string is pinned rather
/// than trusted.
struct SystemSettingsLinkTests {

    @Test func theAudioCapturePaneHasAnAddress() throws {
        let url = try #require(
            SystemSettingsLink.audioCapturePrivacy,
            "the URL does not parse, so the button opens nothing")

        #expect(url.scheme == "x-apple.systempreferences")
    }

    /// Capturing system audio is listed under Screen & System Audio Recording,
    /// even though CoreEQ never records a screen. Anyone tidying this towards a
    /// microphone or audio pane would send users somewhere CoreEQ is not listed.
    @Test func theAddressPointsAtScreenAndSystemAudioRecording() throws {
        let url = try #require(SystemSettingsLink.audioCapturePrivacy)

        #expect(url.absoluteString.hasSuffix("?Privacy_ScreenCapture"))
    }
}
