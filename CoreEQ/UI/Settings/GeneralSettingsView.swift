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

    var body: some View {
        Form {
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
                    if let action = permission.action {
                        Button(action.title) { perform(action) }
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
    /// The one thing to do about the permission, when there is one.
    private enum PermissionAction {
        /// Let macOS raise its prompt, now that CoreEQ has explained itself.
        case request
        /// It was refused, and only System Settings can change that.
        case openSystemSettings

        var title: String {
            switch self {
            case .request: return "Allow Audio Access…"
            case .openSystemSettings: return "Open System Settings…"
            }
        }
    }

    private func perform(_ action: PermissionAction) {
        switch action {
        case .request: EngineActions.shared.requestPermission()
        case .openSystemSettings: openPrivacySettings()
        }
    }

    private enum Permission {
        case granted
        case refused
        case notRunning
        /// Never asked for. The one state where CoreEQ can still explain itself
        /// before macOS does the asking.
        case unasked

        var title: String {
            switch self {
            case .granted: return "Granted"
            case .refused: return "Not granted"
            case .notRunning: return "Not running"
            case .unasked: return "Not requested"
            }
        }

        var symbol: String {
            switch self {
            case .granted: return "checkmark.circle"
            case .refused: return "exclamationmark.triangle"
            case .notRunning: return "pause.circle"
            case .unasked: return "exclamationmark.circle"
            }
        }

        var isGranted: Bool { self == .granted }

        var action: PermissionAction? {
            switch self {
            case .unasked: return .request
            case .refused: return .openSystemSettings
            case .granted, .notRunning: return nil
            }
        }

        var explanation: String {
            switch self {
            case .granted:
                return
                    "CoreEQ processes the sound you hear. Nothing is recorded, stored, or transmitted."
            case .refused:
                return
                    "Without it CoreEQ cannot process system audio. Grant it under Privacy & Security → "
                    + "Screen & System Audio Recording, then quit and reopen CoreEQ."
            case .notRunning:
                return
                    "CoreEQ has not needed the permission yet, so there is nothing to report."
            case .unasked:
                return
                    "An equalizer has to reach the sound to change it. CoreEQ reads audio on "
                    + "its way to your speakers, adjusts it, and plays it straight back — that "
                    + "is the whole of what the permission is for. Nothing is recorded, stored, "
                    + "or sent anywhere, and quitting CoreEQ hands the audio back immediately.\n\n"
                    + "Allow access, and macOS will ask you to confirm."
            }
        }
    }

    private var permission: Permission {
        if case .awaitingPermission(let offer) = engine.status {
            // Asked once already: macOS will not offer again, so the only thing
            // that helps is System Settings.
            return offer == .askTheSystem ? .unasked : .refused
        }
        switch engine.tapAccess {
        case .granted: return .granted
        case .denied: return .refused
        case .unknown: return .notRunning
        }
    }

    private func openPrivacySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Login item

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
