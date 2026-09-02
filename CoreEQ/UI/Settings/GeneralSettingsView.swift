import AppKit
import SwiftUI

/// What CoreEQ can be told.
///
/// Reached from the gear in the window's header, or from “Settings…” in the
/// status menu — CoreEQ is an accessory application with no App menu, so there
/// is no ⌘, to reach it with.
struct GeneralSettingsView: View {
    /// Mirrors the system's answer rather than storing one of its own. Refreshed
    /// whenever the app is brought forward, because the user can revoke the login
    /// item in System Settings while this is on screen.
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var loginItemFailed = false

    @ObservedObject private var engine = EngineStatusBridge.shared
    @ObservedObject private var route = SettingsRoute.shared

    /// What is stopping the equalizer, if anything.
    ///
    /// Waiting for permission is deliberately not a problem: the section below
    /// is already about exactly that, and saying it twice on one pane would read
    /// as two faults rather than one.
    private var engineProblem: String? {
        guard case .failed(_, let message) = engine.status else { return nil }
        return message
    }

    var body: some View {
        Form {
            // First, when there is one: someone who arrives here from a warning
            // came to find out what is wrong, and should not have to look.
            if let problem = engineProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.label)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Show Diagnostics") { route.tab = .diagnostics }
                }
            }

            Section {
                Toggle("Open CoreEQ at login", isOn: loginItemBinding)
                    .help("Start CoreEQ automatically, in the menu bar, when you log in")

                if loginItemFailed {
                    Label(
                        "macOS refused the change. Open System Settings → General → Login Items to set it there.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                }
            } footer: {
                Text("CoreEQ has no window at login — it waits in the menu bar.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Release the audio device when nothing is playing", isOn: idleBinding)
                    .help("Lets the Mac sleep on schedule while CoreEQ is running")
            } footer: {
                Text(
                    "Holding the audio device keeps a Mac awake. CoreEQ lets go after half a "
                        + "minute of silence and takes it back the moment something plays. Turn "
                        + "this off if your audio misbehaves."
                )
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            }

            Section {
                // Laid out here rather than with `LabeledContent`, which places
                // its value column on its own alignment and insets — that is
                // what left the button at a different margin from every other
                // row. An `HStack` with a `Spacer` puts the trailing edge on the
                // form's own margin, so the button lines up with the toggle in
                // the section above.
                HStack(spacing: 12) {
                    Text("System Audio Recording")

                    Spacer(minLength: 12)

                    Label(permission.title, systemImage: permission.symbol)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(
                            permission.isGranted
                                ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

                    // Only when there is genuinely something to do. "Not
                    // determined" is not a problem, and offering to fix it is
                    // the same mistake as calling it refused: it sends someone
                    // to correct something that is not wrong.
                    //
                    // Prominent because arriving here from the menu bar means
                    // having been sent to do something, and the something has to
                    // be obvious at a glance.
                    if permission.needsAction {
                        Button("Open System Settings…") {
                            SystemSettingsLink.openAudioCapturePrivacy()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } footer: {
                Text(permission.explanation)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Coming back from System Settings is the likeliest way for either of
            // these to have changed underneath us.
            opensAtLogin = LoginItem.isEnabled
        }
    }

    // MARK: - The permission

    /// What CoreEQ can honestly say about the permission.
    ///
    /// There is no API that answers "may I tap system audio". The only ground
    /// truth is whether a tap was created, so this reports what the engine
    /// actually observed.
    ///
    /// Notably *not* derived from the engine failing. The engine has failures
    /// that happen before a tap is ever attempted — refusing an unsupported
    /// output device is one — and reading those as a refusal tells the user
    /// their permission is missing when it is granted, sending them to System
    /// Settings to fix something that is not broken.
    private enum Permission {
        case granted
        case refused
        case notRunning

        var title: String {
            switch self {
            case .granted: return "Granted"
            case .refused: return "Not granted"
            case .notRunning: return "Not running"
            }
        }

        var symbol: String {
            switch self {
            case .granted: return "checkmark.circle"
            case .refused: return "exclamationmark.triangle"
            case .notRunning: return "pause.circle"
            }
        }

        var isGranted: Bool { self == .granted }

        /// Whether there is anything for the user to do here.
        ///
        /// Both "never asked" and "refused" get the same button. macOS cannot
        /// distinguish them for us, and an app that guesses shows the wrong one
        /// sometimes; the fallback named in the footer covers the case where the
        /// button cannot help.
        var needsAction: Bool {
            switch self {
            case .refused: return true
            case .granted, .notRunning: return false
            }
        }

        var explanation: String {
            switch self {
            case .granted:
                return
                    "CoreEQ processes the sound you hear. Nothing is recorded, stored, or transmitted."
            case .refused:
                return
                    "Without it CoreEQ cannot process system audio.\n\n"
                    + Theme.audioPermissionInstruction
            case .notRunning:
                return
                    "CoreEQ has not needed the permission yet, so there is nothing to report."
            }
        }
    }

    private var permission: Permission {
        switch engine.tapAccess {
        case .granted: return .granted
        case .denied: return .refused
        case .unknown: return .notRunning
        }
    }

    // MARK: - Login item

    /// Written straight to `SettingsStore`, and read by the engine on its next
    /// idle check rather than pushed. Half a second late is invisible for a
    /// setting, and it keeps the settings scene from needing the engine — which
    /// it cannot be handed, being a separate scene.
    private var idleBinding: Binding<Bool> {
        Binding(
            get: { SettingsStore().pausesWhenSilent },
            set: { SettingsStore().pausesWhenSilent = $0 }
        )
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { opensAtLogin },
            set: { wanted in
                opensAtLogin = wanted
                let succeeded = LoginItem.setEnabled(wanted)
                loginItemFailed = !succeeded
                // Whatever happened, the control ends up showing the system's
                // answer rather than the user's request.
                opensAtLogin = LoginItem.isEnabled
            }
        )
    }
}
