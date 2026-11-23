import SwiftUI
import Testing

@testable import CoreEQ

extension SnapshotTests {
    /// The Settings window, pane by pane, in both appearances.
    ///
    /// Each pane is drawn from `SettingsFacts` rather than from the machine: the
    /// tests run hosted in the app, where the standard defaults and the login item
    /// are the user's own CoreEQ's.
    @MainActor
    @Suite
    struct SettingsSnapshotTests {
        /// The size `SettingsView` gives every pane.
        private let paneSize = CGSize(width: 560, height: 420)

        /// General is a form that scrolls in the window. Drawn taller here, so
        /// the snapshot holds all of it — the permission row at the bottom is
        /// the part with the most to say.
        private let formSize = CGSize(width: 560, height: 720)

        private func facts(_ defaults: UserDefaults = InMemoryDefaults()) -> SettingsFacts {
            SettingsFacts(
                defaults: defaults, opensAtLogin: false, appVersion: "1.10",
                diagnosticsReport: Self.report)
        }

        /// Points the shared engine bridge, which General reads, at an engine
        /// showing `status` and `access`.
        private func showEngine(_ status: AudioEngine.Status, access: TapAccess) -> AudioEngine {
            let engine = AudioEngine(settings: SettingsStore(defaults: InMemoryDefaults()))
            engine.showStatusForSnapshot(status)
            engine.showTapAccessForSnapshot(access)
            EngineStatusBridge.shared.follow(engine)
            return engine
        }

        @Test(arguments: SnapshotAppearance.allCases)
        func general(_ appearance: SnapshotAppearance) async {
            let engine = showEngine(.running(deviceName: "MacBook Pro Speakers"), access: .granted)
            await expectSnapshot(
                GeneralSettingsView().environment(\.settingsFacts, facts()),
                size: formSize, named: "general", appearance: appearance)
            withExtendedLifetime(engine) {}
        }

        /// The longest form of the pane: a fault at the top, and the permission
        /// asking to be fixed.
        @Test(arguments: SnapshotAppearance.allCases)
        func generalWithAProblem(_ appearance: SnapshotAppearance) async {
            let engine = showEngine(
                .failed(
                    summary: "Can’t reach the output",
                    message:
                        "CoreEQ couldn’t start on “MacBook Pro Speakers”. Choose another output, or restart the Mac."
                ),
                access: .denied)
            await expectSnapshot(
                GeneralSettingsView().environment(\.settingsFacts, facts()),
                size: formSize, named: "general-problem", appearance: appearance)
            withExtendedLifetime(engine) {}
        }

        /// Apps every Mac has, so the names and icons are the same anywhere.
        @Test(arguments: SnapshotAppearance.allCases)
        func exclusions(_ appearance: SnapshotAppearance) async {
            let defaults = InMemoryDefaults()
            let settings = SettingsStore(defaults: defaults)
            settings.exclusionListBundleIDs = [
                "com.apple.Music", "com.apple.Safari", "com.apple.FaceTime",
            ]
            settings.excludedBundleIDs = ["com.apple.FaceTime"]

            await expectSnapshot(
                ExclusionsSettingsView().environment(\.settingsFacts, facts(defaults)),
                size: paneSize, named: "exclusions", appearance: appearance)
        }

        @Test(arguments: SnapshotAppearance.allCases)
        func diagnostics(_ appearance: SnapshotAppearance) async {
            await expectSnapshot(
                DiagnosticsSettingsView().environment(\.settingsFacts, facts()),
                size: paneSize, named: "diagnostics", appearance: appearance)
        }

        @Test(arguments: SnapshotAppearance.allCases)
        func about(_ appearance: SnapshotAppearance) async {
            await expectSnapshot(
                AboutSettingsView().environment(\.settingsFacts, facts()),
                size: paneSize, named: "about", appearance: appearance)
        }

        /// A report from the real formatter, about a Mac that never changes: the
        /// pane shows the report verbatim, so its layout is what is under test.
        private static let report = DiagnosticsReport.text(
            appVersion: "1.10 (14)",
            systemVersion: "Version 26.1 (Build 25B78)",
            permission: .granted,
            devices: [
                DiagnosticsReport.Device(
                    name: "MacBook Pro Speakers", uid: "BuiltInSpeakerDevice",
                    transport: "Built-in",
                    isAggregate: false, isDefaultOutput: true, bufferChannels: [2],
                    streamChannels: [2], preferredStereo: StereoPair(left: 0, right: 1)),
                DiagnosticsReport.Device(
                    name: "External Headphones", uid: "BuiltInHeadphoneOutputDevice",
                    transport: "Built-in", isAggregate: false, isDefaultOutput: false,
                    bufferChannels: [2], streamChannels: [2],
                    preferredStereo: StereoPair(left: 0, right: 1)),
            ],
            engine: DiagnosticsReport.Engine(
                status: "running", deviceName: "MacBook Pro Speakers", sampleRate: 48_000,
                tapChannels: 2, isDeviceBound: true, boundStream: 0, destinations: [0, 1],
                aggregateChannels: 2),
            now: Date(timeIntervalSince1970: 1_795_000_000))
    }
}
