import Foundation
import Testing

/// What each permission state tells the user, and which button it offers.
///
/// The overlay, the General settings row and the menu all read from this, so a
/// wrong mapping here is wrong everywhere at once — and the wrong button is
/// worse than none: "Open System Settings…" for a permission never asked sends
/// someone to a list CoreEQ is not in yet.
struct PermissionPromptTests {

    /// Nothing to ask of the user, nothing on screen.
    @Test func grantedAndUnknownNeedNoPrompt() {
        #expect(PermissionPrompt(access: .granted) == nil)
        #expect(
            PermissionPrompt(access: .unknown) == nil,
            "nothing observed is not a problem, and a prompt for it is the old false alarm")
    }

    /// Every state that needs the user has a prompt, and nothing else does.
    @Test func aPromptExistsExactlyWhenActionIsNeeded() {
        for access: TapAccess in [.granted, .notDetermined, .denied, .unknown] {
            #expect((PermissionPrompt(access: access) != nil) == access.needsAction)
        }
    }

    /// Never asked: explain first, then let macOS ask. The explanation is the
    /// whole point of not raising the prompt at launch.
    @Test func notAskedOffersToAsk() throws {
        let prompt = try #require(PermissionPrompt(access: .notDetermined))

        #expect(prompt.primary == .allow)
        #expect(prompt.secondary == nil)
        #expect(prompt.explanation == PermissionPrompt.whatItIsFor)
    }

    /// Refused: macOS will not ask again, so the only way is System Settings.
    /// Offering "Allow…" here would be a button that does nothing.
    @Test func aRefusalSendsToSystemSettings() throws {
        let prompt = try #require(PermissionPrompt(access: .denied))

        #expect(prompt.primary == .openSystemSettings)
        #expect(!prompt.explanation.contains("off and on"))
    }

    /// macOS settles the permission once per process: switched on in System
    /// Settings, it does nothing for the CoreEQ already running. A card that
    /// said "starts as soon as you do" was measured to sit there forever.
    @Test func aRefusalOffersARelaunch() throws {
        let prompt = try #require(PermissionPrompt(access: .denied))

        #expect(prompt.secondary == .relaunch)
        #expect(prompt.explanation.contains("Quit & Reopen"))
        #expect(!prompt.explanation.contains("as soon as"))
    }

    /// Without TCC to ask, a refusal and an entry left by an update look the
    /// same, so the denied wording has to cover both.
    @Test func withoutTCCARefusalAlsoCoversAStaleEntry() throws {
        let prompt = try #require(PermissionPrompt(access: .denied, canAskMacOS: false))

        #expect(prompt.explanation.contains("off and on again"))
    }

    /// The menu is as wide as its widest row, so its titles stay short.
    @Test func menuTitlesFitAMenu() {
        for access: TapAccess in [.notDetermined, .denied] {
            let title = PermissionPrompt(access: access)?.menuTitle ?? ""
            #expect(!title.isEmpty)
            #expect(title.count <= 30, "“\(title)” would widen the whole menu")
        }
    }
}
