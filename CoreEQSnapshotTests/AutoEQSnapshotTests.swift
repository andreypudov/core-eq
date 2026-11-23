import SwiftUI
import Testing

@testable import CoreEQ

extension SnapshotTests {
    /// The AutoEQ window, the by-hand guide it leads to, and the sheet every import
    /// passes through, in both appearances.
    ///
    /// Nothing reaches the network: the catalog comes from a fixture cache and the
    /// one correction it downloads from `StubURLProtocol`, the same fixtures the
    /// store's own tests use.
    @MainActor
    @Suite
    struct AutoEQSnapshotTests {
        /// The browser with a model chosen: the catalog loads from the cache as
        /// the window appears, a model is chosen from the list, and its
        /// correction loads into the preview — each by the window's own code.
        @Test(arguments: SnapshotAppearance.allCases)
        func browserWithAPreview(_ appearance: SnapshotAppearance) async throws {
            try await expectBrowser(
                serving: AutoEQTestFixtures.profileText, named: "browser", appearance: appearance)
        }

        /// The same, for a correction CoreEQ would change on import: a preamp
        /// and a gain beyond what it can play. The note under the preview says
        /// so before anyone presses Import.
        @Test(arguments: SnapshotAppearance.allCases)
        func browserWithAnAdjustedPreview(_ appearance: SnapshotAppearance) async throws {
            try await expectBrowser(
                serving: """
                    Preamp: -20.0 dB
                    Filter 1: ON PK Fc 1000 Hz Gain 25.0 dB Q 1.41
                    Filter 2: ON LSC Fc 105 Hz Gain 5.0 dB Q 0.70
                    """,
                named: "browser-adjusted", appearance: appearance)
        }

        private func expectBrowser(
            serving profile: String, named name: String, appearance: SnapshotAppearance,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            let cache = AutoEQTestFixtures.makeCacheDirectory()
            defer { AutoEQTestFixtures.remove(cache) }
            try AutoEQTestFixtures.writeCache(into: cache)
            StubURLProtocol.setHandler(AutoEQTestFixtures.catalogHandler(profile: profile))
            defer { StubURLProtocol.setHandler(nil) }

            let fixtures = Fixtures()
            let store = AutoEQStore(
                service: AutoEQNetworkService(session: .autoEQStubbed(), cacheDirectory: cache))

            await expectSnapshot(
                AutoEQBrowserView(
                    store: store, profileManager: fixtures.manager, audioEngine: fixtures.engine,
                    onClose: {}, onImportByHand: {}),
                size: CGSize(width: 600, height: 680), named: name, appearance: appearance,
                settle: 1,
                afterAppearing: {
                    // As a person would: wait for the list, then choose. The
                    // window's own handlers load the correction from there.
                    while store.catalogState != .loaded {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    store.selectModel(named: "Alpha Headphones")
                },
                sourceLocation: sourceLocation)
        }

        /// The route for a correction the catalog doesn't have.
        @Test(arguments: SnapshotAppearance.allCases)
        func importByHandGuide(_ appearance: SnapshotAppearance) async {
            await expectSnapshot(
                AutoEQGuideSheet(onPaste: {}), width: 480, named: "guide", appearance: appearance)
        }

        /// The disclosure every import shows when CoreEQ has to change values: a
        /// preamp and a gain beyond what it can play.
        @Test(arguments: SnapshotAppearance.allCases)
        func importConfirmation(_ appearance: SnapshotAppearance) async throws {
            let fixtures = Fixtures()
            let preview = try fixtures.manager.previewImport(
                text: """
                    Preamp: -20.0 dB
                    Filter 1: ON PK Fc 1000 Hz Gain 25.0 dB Q 1.00
                    Filter 2: ON LSC Fc 105 Hz Gain 5.0 dB Q 0.70
                    Filter 3: ON HSC Fc 9500 Hz Gain -3.0 dB Q 0.70
                    """,
                suggestedName: "Alpha Headphones")

            await expectSnapshot(
                ImportConfirmationSheet(preview: preview, onConfirm: { _ in }, onCancel: {}),
                width: 520, named: "import-confirmation", appearance: appearance)
        }
    }
}
