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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            } footer: {
                Text("CoreEQ has no window at login — it waits in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("System Audio Recording") {
                    HStack(spacing: 8) {
                        Label(permission.title, systemImage: permission.symbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(
                                permission.isGranted
                                    ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

                        // Only when it has actually been refused. "Not
                        // determined" is not a problem to fix, and offering the
                        // fix for it is the same mistake as calling it refused:
                        // it sends someone to System Settings to correct
                        // something that is not wrong.
                        if permission == .refused {
                            Button("Open System Settings…") { openPrivacySettings() }
                        }
                    }
                }
            } footer: {
                Text(permission.explanation)
                    .font(.callout)
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
