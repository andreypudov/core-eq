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
    @State private var opensAtLogin = false
    @State private var loginItemFailed = false

    @Environment(\.settingsFacts) private var facts

    @ObservedObject private var engine = EngineStatusBridge.shared
    @ObservedObject private var route = SettingsRoute.shared

    /// What is stopping the equalizer, if anything.
    ///
    /// Waiting for permission is deliberately not a problem: the section below
    /// is already about exactly that, and saying it twice on one pane would read
    /// as two faults rather than one.
    private var engineProblem: String? {
        if case .failed(_, let message) = engine.status { return message }
        return engine.exclusiveHold?.message
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
                        "CoreEQ couldn’t change its login item. Open System Settings > General > Login Items to change it there.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                }
            } footer: {
                Text("At login, CoreEQ opens in the menu bar, without a window.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Release the audio device when nothing is playing", isOn: idleBinding)
                    .help("Lets the Mac sleep on schedule while CoreEQ is running")
            } footer: {
                Text(
                    "Holding the audio device keeps a Mac awake. CoreEQ lets go after half a minute of silence and takes it back the moment something plays. Turn this off if your audio misbehaves."
                )
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pause while recording system audio", isOn: recordingBinding)
                    .help("Keeps screen recordings from capturing the sound twice")
            } footer: {
                Text(Theme.recordingPauseExplanation)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }

            Section {
                // Reflows rather than squeezes, whatever the language: one
                // line when the title, the status, and the buttons all fit at
                // their own size; then the buttons on a line of their own;
                // then a line each, with the title free to wrap. Squeezed onto
                // one line, “Relaunch CoreEQ” came out as “Relaunch Core…” in
                // English. See “Room for every language” in STRINGS.org.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        permissionTitleAndStatus(wraps: false)
                        permissionActions
                    }

                    VStack(alignment: .trailing, spacing: 10) {
                        HStack(spacing: 12) { permissionTitleAndStatus(wraps: false) }
                        HStack(spacing: 12) { permissionActions }
                    }

                    VStack(alignment: .trailing, spacing: 10) {
                        HStack(spacing: 12) { permissionTitleAndStatus(wraps: true) }
                        permissionActions
                    }
                }
            } footer: {
                Text(permissionExplanation)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { opensAtLogin = facts.isLoginItemEnabled }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Coming back from System Settings is the likeliest way for either of
            // these to have changed underneath us.
            opensAtLogin = facts.isLoginItemEnabled
        }
    }

    // MARK: - The permission

    /// Laid out by hand rather than with `LabeledContent`, which places its
    /// value column on its own alignment and insets — that is what left the
    /// button at a different margin from every other row. A `Spacer` puts the
    /// trailing edge on the form's own margin, so the status and the buttons
    /// line up with the toggles in the sections above.
    ///
    /// The title keeps one line until the last layout, where it may wrap
    /// rather than push the status off the row.
    @ViewBuilder private func permissionTitleAndStatus(wraps: Bool) -> some View {
        Text("System Audio Recording")
            .fixedSize(horizontal: !wraps, vertical: true)

        Spacer(minLength: 12)

        Label(permission.title, systemImage: permission.symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(
                permission.isGranted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
            )
            .fixedSize()
    }

    /// Only when there is genuinely something to do. "Not determined this
    /// session" is not a problem, and offering to fix it is the same mistake as
    /// calling it refused: it sends someone to correct something that is not
    /// wrong.
    ///
    /// Prominent because arriving here from the menu bar means having been
    /// sent to do something, and the something has to be obvious at a glance.
    /// The same buttons as the main window's, from the same `PermissionPrompt`.
    /// Never narrower than their titles: a button is never cut off.
    @ViewBuilder private var permissionActions: some View {
        if let action = prompt?.secondary {
            Button(action.title) { engine.perform(action) }
                .fixedSize()
        }
        if let action = prompt?.primary {
            Button(action.title) { engine.perform(action) }
                .buttonStyle(.borderedProminent)
                .fixedSize()
        }
    }

    /// What CoreEQ can honestly say about the permission.
    ///
    /// Read from the engine's `TapAccess`, which asks macOS where it can and
    /// otherwise reports only what a tap showed. Notably *not* derived from the
    /// engine failing: it has failures that happen before a tap is ever
    /// attempted, and reading those as a refusal sends someone to System
    /// Settings to fix something that is not broken.
    private enum Permission {
        case granted
        case notAsked
        case refused
        case notRunning

        init(_ access: TapAccess) {
            switch access {
            case .granted: self = .granted
            case .notDetermined: self = .notAsked
            case .denied: self = .refused
            case .unknown: self = .notRunning
            }
        }

        var title: String {
            switch self {
            case .granted:
                return String(localized: "Granted", comment: "Audio permission status")
            case .notAsked:
                return String(localized: "Not asked yet", comment: "Audio permission status")
            case .refused:
                return String(localized: "Not granted", comment: "Audio permission status")
            case .notRunning:
                return String(
                    localized: "Not running",
                    comment: "Audio permission status: CoreEQ hasn’t needed it yet")
            }
        }

        var symbol: String {
            switch self {
            case .granted: return "checkmark.circle"
            case .notAsked: return "questionmark.circle"
            case .refused: return "exclamationmark.triangle"
            case .notRunning: return "pause.circle"
            }
        }

        var isGranted: Bool { self == .granted }
    }

    private var permission: Permission { Permission(engine.tapAccess) }

    /// The button and the words for a state that needs the user, shared with
    /// the main window so the two never disagree.
    private var prompt: PermissionPrompt? {
        PermissionPrompt(access: engine.tapAccess, canAskMacOS: AudioCapturePermission.isAvailable)
    }

    private var permissionExplanation: String {
        if let prompt { return prompt.explanation }
        switch permission {
        case .granted:
            return String(
                localized:
                    "CoreEQ equalizes the sound you hear. Nothing is recorded, stored, or sent anywhere.",
                comment: "Audio permission explanation, when it’s granted")
        default:
            return String(
                localized: "CoreEQ hasn’t needed the permission yet, so there’s nothing to report.",
                comment: "Audio permission explanation, before CoreEQ has asked")
        }
    }

    // MARK: - Login item

    /// Written straight to `SettingsStore`, and read by the engine on its next
    /// idle check rather than pushed. Half a second late is invisible for a
    /// setting, and it keeps the settings scene from needing the engine — which
    /// it cannot be handed, being a separate scene.
    private var idleBinding: Binding<Bool> {
        Binding(
            get: { facts.settings.pausesWhenSilent },
            set: { facts.settings.pausesWhenSilent = $0 }
        )
    }

    /// Read by the engine on its next idle check, like `idleBinding`.
    private var recordingBinding: Binding<Bool> {
        Binding(
            get: { facts.settings.pausesWhileRecording },
            set: { facts.settings.pausesWhileRecording = $0 }
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
                opensAtLogin = facts.isLoginItemEnabled
            }
        )
    }
}
