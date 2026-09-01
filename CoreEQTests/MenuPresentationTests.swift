import Testing

/// Opening a window from a status menu.
///
/// What is testable here is the contract, not the AppKit behaviour behind it:
/// that the presentation is *deferred* rather than run where the caller stands.
/// That is exactly what regressed — the menu action called straight through,
/// inside the menu's tracking loop, and the window opened behind other apps
/// whenever the menu had not finished closing.
///
/// The deferral reads like indirection for its own sake at the call site. These
/// tests are what makes removing it fail loudly rather than intermittently.
@MainActor
struct MenuPresentationTests {

    /// The rule, stated once: never synchronously.
    @Test func aPresentationIsNotRunWhereItIsAskedFor() {
        var presented = false

        MenuPresentation.afterMenuCloses(using: { _ in }, { presented = true })

        #expect(
            presented == false,
            "presented inside the menu's tracking loop, where activation does not take")
    }

    /// And it is not merely dropped.
    @Test func aPresentationRunsOnceTheMenuHasClosed() {
        var deferred: (@MainActor () -> Void)?
        var presented = false

        MenuPresentation.afterMenuCloses(using: { deferred = $0 }, { presented = true })
        #expect(presented == false)

        deferred?()

        #expect(presented == true, "the presentation was deferred and then never run")
    }

    /// Each call defers its own work, so two menu items opening two windows do
    /// not collapse into one.
    @Test func everyPresentationIsDeferredSeparately() {
        var deferred: [@MainActor () -> Void] = []
        var opened: [String] = []

        let collect: MenuPresentation.Schedule = { deferred.append($0) }
        MenuPresentation.afterMenuCloses(using: collect, { opened.append("window") })
        MenuPresentation.afterMenuCloses(using: collect, { opened.append("settings") })

        #expect(deferred.count == 2)
        for present in deferred { present() }
        #expect(opened == ["window", "settings"])
    }
}
