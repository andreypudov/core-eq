import CoreAudio
import Foundation
import Testing

/// The rules for leaving apps out of the tap.
///
/// The parts that decide whether an exclusion works at all. Each was settled
/// by measurement on hardware, and each is the kind of line a later tidy-up
/// removes without noticing what it was for.
struct AppExclusionTests {

    // MARK: - The stored list

    @Test func theListIsTrimmedAndKeepsItsOrder() {
        let list = AppExclusion.normalized(
            ["  com.apple.logic10 ", "com.presonus.studioone6", ""], ownBundleID: nil)
        #expect(list == ["com.apple.logic10", "com.presonus.studioone6"])
    }

    /// Bundle identifiers are compared without case, so the same app added
    /// twice from two places is one row.
    @Test func anAppAddedTwiceIsListedOnce() {
        let list = AppExclusion.normalized(
            ["com.apple.Music", "com.apple.music", "com.apple.Music"], ownBundleID: nil)
        #expect(list == ["com.apple.Music"])
    }

    /// CoreEQ is always out of its own tap, by process. Listing it as a choice
    /// would be a row that does nothing.
    @Test func coreEQItselfIsNeverListed() {
        let list = AppExclusion.normalized(
            ["com.andreypudov.coreeq", "com.apple.Music"], ownBundleID: "com.andreypudov.CoreEQ")
        #expect(list == ["com.apple.Music"])
    }

    // MARK: - The tap

    private func description() -> CATapDescription {
        CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    }

    /// The restore flag is the half that is easy to lose: without it, an
    /// excluded app was measured coming back into the tap as soon as it was
    /// relaunched.
    @Test func anExcludedAppIsRestoredAcrossRelaunches() throws {
        guard #available(macOS 26, *) else { return }
        let tap = description()
        tap.isProcessRestoreEnabled = false

        AppExclusion.apply(["com.apple.logic10"], to: tap)

        #expect(tap.bundleIDs == ["com.apple.logic10"])
        #expect(tap.isProcessRestoreEnabled)
        #expect(tap.isExclusive, "the tap still takes everything except the list")
    }

    /// Nothing excluded is the tap every earlier version built, untouched.
    @Test func anEmptyListLeavesTheTapAlone() throws {
        guard #available(macOS 26, *) else { return }
        let tap = description()
        tap.isProcessRestoreEnabled = false

        AppExclusion.apply([], to: tap)

        #expect(tap.bundleIDs.isEmpty)
        #expect(!tap.isProcessRestoreEnabled)
    }

    // MARK: - What is offered

    @Test func anInstalledAppIsOffered() {
        #expect(
            AppExclusion.isStandaloneApp(at: URL(fileURLWithPath: "/Applications/Logic Pro.app")))
        #expect(
            AppExclusion.isStandaloneApp(
                at: URL(fileURLWithPath: "/System/Applications/Music.app")))
    }

    /// Safari plays through this. Excluding it by identifier was measured to do
    /// nothing, so it must never appear as a choice.
    @Test func webKitsSharedHelperIsNotOffered() {
        let helper = URL(
            fileURLWithPath:
                "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
                + "com.apple.WebKit.GPU.xpc")
        #expect(!AppExclusion.isStandaloneApp(at: helper))
    }

    /// Chromium's helpers are apps of their own, nested inside the browser.
    @Test func anAppNestedInsideAnotherIsNotOffered() {
        let helper = URL(
            fileURLWithPath:
                "/Applications/Google Chrome.app/Contents/Frameworks/"
                + "Google Chrome Framework.framework/Helpers/Google Chrome Helper.app")
        #expect(!AppExclusion.isStandaloneApp(at: helper))
    }

    @Test func somethingThatIsNotAnAppIsNotOffered() {
        #expect(!AppExclusion.isStandaloneApp(at: URL(fileURLWithPath: "/usr/bin/afplay")))
    }
}
