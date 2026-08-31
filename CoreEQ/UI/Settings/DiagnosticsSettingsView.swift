import AppKit
import SwiftUI

/// What CoreEQ sees, in one copyable block.
///
/// This pane exists because of how the audio defects in this app get reported:
/// someone says "no sound on my interface", and working out why has meant
/// guessing at what their device presents. The facts that settle it are all
/// readable in a few milliseconds — the device's channel layout, its streams,
/// which tap the engine got, where it put the channels — so the person hitting
/// the bug can send them instead of a description.
struct DiagnosticsSettingsView: View {
    @ObservedObject private var bridge = EngineStatusBridge.shared
    @ObservedObject private var profiles = ProfileStatusBridge.shared

    @State private var report = ""
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio diagnostics")
                .font(Theme.Font.heading)

            Text(
                "What CoreEQ sees on this Mac. Include this with a bug report — it "
                    + "answers most questions about audio problems. It lists your audio "
                    + "device names and contains nothing else about you."
            )
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView([.horizontal, .vertical]) {
                Text(report)
                    .font(Theme.Font.report)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack {
                Button(didCopy ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    didCopy = true
                }
                .disabled(report.isEmpty)

                Button("Refresh") { refresh() }

                Spacer()
            }
        }
        .padding(16)
        .onAppear(perform: refresh)
        // The engine republishes when it restarts — on a device change, or after
        // wake — and a report describing the previous device would be worse than
        // no report at all.
        .onChange(of: bridge.diagnostics) { refresh() }
        .onChange(of: profiles.activeProfileName) { refresh() }
        .onChange(of: profiles.abSlot) { refresh() }
        .onChange(of: profiles.deviceListUpdates) { refresh() }
    }

    private func refresh() {
        didCopy = false
        report = DiagnosticsReport.text(
            appVersion: Self.appVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            permission: bridge.tapAccess,
            devices: AudioDevices.deviceReports(),
            engine: bridge.diagnostics,
            profiles: Self.profiles(live: profiles)
        )
    }

    /// Read straight from the store rather than from `ProfileManager`, which
    /// this scene cannot reach. The store is the thing that actually decides
    /// what survives a relaunch, so it is also the right thing to report.
    private static func profiles(live: ProfileStatusBridge) -> DiagnosticsReport.Profiles {
        let settings = SettingsStore()
        // The manager's own idea of the device, not the system's: if those two
        // ever disagree that is itself the bug, and reporting the system's would
        // hide it.
        let uid = live.outputDeviceUID
        let stored = settings.deviceStates[uid ?? ""]
        return DiagnosticsReport.Profiles(
            currentDeviceUID: uid,
            savedSlots: settings.deviceStates.keys.sorted(),
            storedProfileName: stored?.profileName,
            storedSlot: stored?.liveSlot.label,
            liveProfileName: live.activeProfileName,
            liveSlot: live.abSlot?.label,
            deviceListUID: live.deviceListUID,
            deviceListUpdates: live.deviceListUpdates,
            systemDeviceUID: AudioDevices.defaultOutputDeviceID()
                .flatMap(AudioDevices.persistentID(of:))
        )
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
