import AppKit

/// Quits CoreEQ and opens it again.
///
/// For the permission, which macOS settles once per process: switched on in
/// System Settings, it reaches CoreEQ only on the next launch. macOS offers to
/// quit and reopen the app itself, but that dialog is easy to dismiss, and
/// someone who did is left with a card saying "not allowed" over a switch that
/// is on. This is the same thing from a button that stays put.
enum AppRelaunch {
    /// The waiting is done by a small process outside CoreEQ, because the new
    /// instance has to start after this one has gone. Opened alongside it, two
    /// copies would briefly put two icons in the menu bar and, with the
    /// permission given, two taps on the same audio.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(
            pid: ProcessInfo.processInfo.processIdentifier, bundlePath: Bundle.main.bundlePath)
        do {
            try process.run()
        } catch {
            // Nothing launched, so quitting would leave nothing running. The card
            // still says what to do by hand.
            return
        }
        NSApp.terminate(nil)
    }

    /// The script waits for this process to exit, then opens the bundle.
    ///
    /// The process ID and the path are passed as the script's own arguments
    /// (`$0`, `$1`) and quoted there, never spliced into the script text, so a
    /// path with spaces or quotes in it is only ever a path.
    static func arguments(pid: Int32, bundlePath: String) -> [String] {
        [
            "-c",
            "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$1\"",
            String(pid),
            bundlePath,
        ]
    }
}
