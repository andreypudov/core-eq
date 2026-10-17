import AppKit

/// Makes sure only one copy of CoreEQ runs, before either builds an audio path.
///
/// Two copies silence the Mac. Each one's tap leaves out only its own process,
/// so each captures — and, once proven, mutes — the other's equalized output,
/// and nothing reaches the speakers at all. Seen in practice: macOS's own
/// "Quit & Reopen", offered after the permission is switched on, reopens
/// CoreEQ by bundle identifier, and it picked the installed copy while a
/// development build was being started by hand. A Homebrew copy beside a
/// downloaded one, or a login item beside a manual launch, gets there too.
///
/// The copy being launched asks, rather than either side deciding: the one just
/// started is usually the one wanted, but not always, and guessing wrong is
/// either a silent Mac or the wrong version running without a word.
@MainActor
enum SingleInstance {

    /// Calls `proceed` once this is the only copy, or quits this one.
    static func ensure(then proceed: @escaping @MainActor () -> Void) {
        let others = otherCopies()
        guard !others.isEmpty else {
            proceed()
            return
        }

        AppActivation.activate()
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Another copy of CoreEQ is running.",
            comment: "Alert title at launch, when CoreEQ is already running")
        let paths = others.compactMap { $0.bundleURL?.path }.joined(separator: "\n")
        let reason = String(
            localized: "Two copies would each silence the other’s sound, so only one can run.",
            comment: "Alert message: why two copies of CoreEQ can’t run together")
        alert.informativeText =
            paths.isEmpty
            ? reason
            : reason + "\n\n"
                + String(
                    localized: "The other copy is at:\n\(paths)",
                    comment: "Alert message: where the other copy of CoreEQ is installed")
        alert.addButton(
            withTitle: String(localized: "Quit the Other Copy", comment: "Alert button"))
        alert.addButton(withTitle: String(localized: "Quit This Copy", comment: "Alert button"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }
        others.forEach { $0.terminate() }
        waitForExit(
            of: others, deadline: Date().addingTimeInterval(5), forced: false, then: proceed)
    }

    private static func otherCopies() -> [NSRunningApplication] {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != own && !$0.isTerminated }
    }

    /// Polled, because `isTerminated` is the one signal there is and it is
    /// updated on the main run loop. A copy that ignores the polite request for
    /// five seconds is forced: its tap dies with the process, so forcing it
    /// leaves nothing behind. One that survives even that means this copy
    /// must not start, or the Mac goes silent after all.
    private static func waitForExit(
        of others: [NSRunningApplication], deadline: Date, forced: Bool,
        then proceed: @escaping @MainActor () -> Void
    ) {
        let running = others.filter { !$0.isTerminated }
        guard !running.isEmpty else {
            proceed()
            return
        }
        if Date() >= deadline {
            guard !forced else {
                NSApp.terminate(nil)
                return
            }
            running.forEach { $0.forceTerminate() }
            waitForExit(
                of: running, deadline: Date().addingTimeInterval(2), forced: true, then: proceed)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                waitForExit(of: others, deadline: deadline, forced: forced, then: proceed)
            }
        }
    }
}
