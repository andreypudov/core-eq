import SwiftUI

/// The Settings window's only pane.
///
/// CoreEQ has no menu bar of its own — it is an accessory application, so there is
/// no App menu — which is why this is reached from the status menu rather than
/// from ⌘, like everywhere else on the system.
struct GeneralSettingsView: View {
    /// Mirrors the system's answer rather than storing one of its own. Refreshed
    /// whenever the window appears or the app is brought forward, because the
    /// user can revoke the login item in System Settings while this is on screen.
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var loginItemFailed = false

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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from System Settings is the likeliest way for this to
            // have changed underneath us.
            opensAtLogin = LoginItem.isEnabled
        }
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
