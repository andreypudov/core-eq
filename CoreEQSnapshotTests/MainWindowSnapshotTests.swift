import SwiftUI
import Testing

@testable import CoreEQ

extension SnapshotTests {
    /// The main window, piece by piece and whole, in both appearances.
    @MainActor
    @Suite
    struct MainWindowSnapshotTests {
        @Test(arguments: SnapshotAppearance.allCases)
        func responsePlot(_ appearance: SnapshotAppearance) async {
            let fixtures = Fixtures()
            await expectSnapshot(
                FrequencyResponseView(
                    filters: fixtures.manager.currentFilters,
                    sampleRate: 48_000,
                    spectrum: fixtures.spectrum
                ),
                size: CGSize(width: 780, height: 320),
                named: "response-plot",
                appearance: appearance)
        }

        @Test(arguments: SnapshotAppearance.allCases)
        func sidebar(_ appearance: SnapshotAppearance) async {
            let fixtures = Fixtures()
            await expectSnapshot(
                EqualizerSidebarView(
                    profileManager: fixtures.manager,
                    audioEngine: fixtures.engine,
                    autoEQStore: AutoEQStore(),
                    openAutoEQBrowser: {}
                )
                .defaultAppStorage(fixtures.viewDefaults),
                size: CGSize(width: 240, height: 760),
                named: "sidebar",
                appearance: appearance)
        }

        @Test(arguments: SnapshotAppearance.allCases)
        func equalizerGraphic(_ appearance: SnapshotAppearance) async {
            let fixtures = Fixtures()
            fixtures.viewDefaults.set("graphic", forKey: "editorTab")
            await expectSnapshot(
                detail(fixtures),
                size: CGSize(width: 880, height: 760),
                named: "equalizer-graphic",
                appearance: appearance)
        }

        @Test(arguments: SnapshotAppearance.allCases)
        func equalizerParametric(_ appearance: SnapshotAppearance) async {
            let fixtures = Fixtures()
            fixtures.manager.addFilter(kind: .bell, frequency: 240, gain: 1.8, q: 3.9)
            fixtures.manager.addFilter(kind: .bell, frequency: 4_100, gain: 6.5, q: 2)
            fixtures.manager.addFilter(kind: .highShelf, frequency: 9_500, gain: -3, q: 0.7)
            fixtures.viewDefaults.set("parametric", forKey: "editorTab")
            await expectSnapshot(
                detail(fixtures),
                size: CGSize(width: 880, height: 760),
                named: "equalizer-parametric",
                appearance: appearance)
        }

        private func detail(_ fixtures: Fixtures) -> some View {
            EqualizerDetailView(
                profileManager: fixtures.manager,
                audioEngine: fixtures.engine,
                spectrum: fixtures.spectrum,
                outputs: fixtures.outputs
            )
            .defaultAppStorage(fixtures.viewDefaults)
        }
    }
}
