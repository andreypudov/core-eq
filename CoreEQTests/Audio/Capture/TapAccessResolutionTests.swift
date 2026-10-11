import Foundation
import Testing

/// What CoreEQ believes about the permission, from TCC's answer and the
/// capture proof together.
///
/// Without TCC the engine could not tell "never asked" from "refused", and
/// could not tell anything on a quiet Mac. With it, TCC decides, and the proof
/// is only evidence when TCC cannot be asked.
struct TapAccessResolutionTests {

    // MARK: - TCC answers

    /// A yes from TCC is believed whatever the tap shows. Silence under a yes
    /// is more likely a player sending nothing than a permission problem, and
    /// calling it "not allowed" would send someone to a switch that is on.
    @Test func aGrantIsBelievedWhateverTheProofSays() {
        for proof: CaptureProof.Verdict? in [nil, .waiting, .proven, .notCapturing] {
            #expect(TapAccess.resolve(tcc: .granted, proof: proof) == .granted)
        }
    }

    /// No tap is built after a refusal, so whatever proof is around belongs to
    /// an earlier answer and must not soften this one.
    @Test func aRefusalIsFinal() {
        for proof: CaptureProof.Verdict? in [nil, .waiting, .proven, .notCapturing] {
            #expect(TapAccess.resolve(tcc: .denied, proof: proof) == .denied)
        }
    }

    /// Never asked is its own state, not a refusal: it wants an explanation and
    /// a button that asks, not directions to System Settings.
    @Test func notAskedIsNeitherGrantedNorRefused() {
        for proof: CaptureProof.Verdict? in [nil, .waiting, .proven, .notCapturing] {
            #expect(TapAccess.resolve(tcc: .notDetermined, proof: proof) == .notDetermined)
        }
    }

    // MARK: - Without TCC

    /// When the private entry point is gone, behaviour is what it was before it
    /// was used: the proof is the only evidence.
    @Test func withoutTCCTheProofDecides() {
        #expect(TapAccess.resolve(tcc: nil, proof: .proven) == .granted)
        #expect(TapAccess.resolve(tcc: nil, proof: .notCapturing) == .denied)
    }

    /// And silence on a quiet Mac is still not a verdict.
    @Test func withoutTCCNothingObservedIsUnknown() {
        #expect(TapAccess.resolve(tcc: nil, proof: nil) == .unknown)
        #expect(TapAccess.resolve(tcc: nil, proof: .waiting) == .unknown)
    }

    // MARK: - What needs the user

    @Test func onlyTheStatesWithSomethingToDoAskForAction() {
        #expect(TapAccess.notDetermined.needsAction)
        #expect(TapAccess.denied.needsAction)
        #expect(!TapAccess.granted.needsAction)
        #expect(
            !TapAccess.unknown.needsAction,
            "nothing observed is not a problem, and offering to fix it is a false alarm")
    }

    // MARK: - TCC's raw answer

    @Test func preflightResultsMapToAnswers() {
        #expect(AudioCapturePermission.answer(fromPreflight: 0) == .granted)
        #expect(AudioCapturePermission.answer(fromPreflight: 1) == .denied)
        #expect(AudioCapturePermission.answer(fromPreflight: 2) == .notDetermined)
        #expect(
            AudioCapturePermission.answer(fromPreflight: -1) == .notDetermined,
            "an unexpected value offers the prompt rather than claiming an answer")
    }

}
