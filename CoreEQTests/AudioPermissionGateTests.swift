import Testing

/// Whether the engine starts, or explains itself first.
///
/// Worth testing on its own because the feature it serves is a promise about
/// something the user sees *before* anything happens: that macOS never asks to
/// record their audio without CoreEQ having said why. A promise like that is
/// only as good as the one branch that gets it wrong, and the branch that did
/// get it wrong was the one nobody would think to check — the app remembering
/// that it asked while macOS does not.
struct AudioPermissionGateTests {

    /// The ordinary case, and the one that must never be interrupted: someone
    /// who has already allowed it hears their equalizer, silently.
    @Test func aGrantedPermissionStartsWithoutComment() {
        #expect(
            AudioPermissionGate.decision(isGranted: true, wasRefused: false) == .start,
            "a granted permission was not enough to start")
        #expect(
            AudioPermissionGate.decision(isGranted: true, wasRefused: true) == .start,
            "a past refusal should not matter once the answer is yes")
    }

    /// Not granted, never refused. Offer to ask, because macOS will prompt.
    ///
    /// This covers more than a new install. macOS forgets its answer when the
    /// app's identity changes — a rebuild, or a re-signed release — and prompts
    /// again as if for the first time. An earlier version keyed this on whether
    /// CoreEQ had asked before, which in that situation sent people to System
    /// Settings to hunt for a switch when a button would have done it.
    @Test func notRefusedMeansOfferToAsk() {
        #expect(
            AudioPermissionGate.decision(isGranted: false, wasRefused: false)
                == .explainFirst(.askTheSystem))
    }

    /// Refused, and still not granted. macOS will not offer again while that
    /// refusal stands, so System Settings is the only thing that can change it.
    @Test func aRefusalOffersSystemSettingsInstead() {
        #expect(
            AudioPermissionGate.decision(isGranted: false, wasRefused: true)
                == .explainFirst(.openSystemSettings))
    }

    /// The guarantee, stated as a test: there is no combination of inputs that
    /// starts the engine without the permission in hand.
    ///
    /// Starting is what creates the tap, and creating the tap is what raises the
    /// system prompt. So any path that starts hopefully is a path where that
    /// prompt can appear with nothing said beforehand. This is the case that
    /// regressed: CoreEQ remembered asking, macOS had forgotten — which happens
    /// on every rebuild, and to any user whose grant lapses.
    @Test(arguments: [true, false])
    func theEngineNeverStartsWithoutThePermission(wasRefused: Bool) {
        let decision = AudioPermissionGate.decision(isGranted: false, wasRefused: wasRefused)

        #expect(decision != .start, "the engine would have started and provoked a prompt")
    }
}
