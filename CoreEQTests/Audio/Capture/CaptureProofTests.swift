import CoreAudio
import Foundation
import Testing

/// Whether a tap has shown it can capture.
///
/// The two defects this guards are opposites, and both shipped in this file's
/// absence. Muting on an unproven tap silenced the Mac while the app reported
/// success. Concluding from silence alone then accused people of refusing a
/// permission they had granted, on every launch where nothing was playing.
struct CaptureProofTests {
    private let interval: TimeInterval = 0.25
    private let limit: TimeInterval = 2

    private func evaluate(
        received: Bool = false, playing: Bool = false, silent: TimeInterval = 0
    ) -> (verdict: CaptureProof.Verdict, silentWhilePlaying: TimeInterval) {
        CaptureProof.evaluate(
            hasReceivedAudio: received, isAnythingPlaying: playing,
            silentWhilePlaying: silent, interval: interval, limit: limit)
    }

    // MARK: - Proof

    /// A single sample is the whole proof. Nothing else about the situation
    /// matters once the tap has delivered.
    @Test func audioArrivingProvesTheTap() {
        #expect(evaluate(received: true, playing: false).verdict == .proven)
        #expect(evaluate(received: true, playing: true).verdict == .proven)
        #expect(
            evaluate(received: true, playing: true, silent: 60).verdict == .proven,
            "a long silence before the first sample is not held against the tap")
    }

    // MARK: - Silence on a quiet Mac

    /// The defect this file exists for. A Mac with nothing playing is quiet,
    /// and an engine that reads that as a refusal accuses the user of something
    /// they did not do.
    @Test func silenceWithNothingPlayingIsNeverAVerdict() {
        var silent: TimeInterval = 0
        // Four minutes of a quiet Mac, at four evaluations a second.
        for _ in 0..<960 {
            let result = evaluate(playing: false, silent: silent)
            #expect(result.verdict == .waiting, "a quiet Mac was read as a refusal")
            silent = result.silentWhilePlaying
        }
    }

    /// And the clock does not run while nothing is playing, so silence cannot
    /// accumulate in the background and convict on the first note.
    @Test func theClockIsResetWhenNothingIsPlaying() {
        let nearlyThere = evaluate(playing: true, silent: limit - interval * 2)
        #expect(nearlyThere.verdict == .waiting)

        let paused = evaluate(playing: false, silent: nearlyThere.silentWhilePlaying)
        #expect(paused.silentWhilePlaying == 0, "silence accrued while playing was kept")

        let resumed = evaluate(playing: true, silent: paused.silentWhilePlaying)
        #expect(resumed.verdict == .waiting, "the first moment of playback convicted the tap")
    }

    // MARK: - Silence while something is playing

    /// Audio flowing and none of it arriving is the one situation that means
    /// the tap is not receiving.
    @Test func silenceWhilePlayingEventuallyConcludes() {
        var silent: TimeInterval = 0
        var verdicts: [CaptureProof.Verdict] = []
        for _ in 0..<Int(limit / interval) {
            let result = evaluate(playing: true, silent: silent)
            verdicts.append(result.verdict)
            silent = result.silentWhilePlaying
        }

        #expect(verdicts.last == .notCapturing, "playing audio never reached a verdict")
        #expect(
            verdicts.dropLast().allSatisfy { $0 == .waiting },
            "the verdict came before the limit")
    }

    /// Just under the limit is still not enough.
    @Test func theLimitIsNotReachedEarly() {
        #expect(evaluate(playing: true, silent: limit - interval * 2).verdict == .waiting)
    }

    /// And once it is reached it stays reached, so the engine can keep polling
    /// without the verdict flickering.
    @Test func theVerdictHoldsWhileTheSilenceContinues() {
        let past = evaluate(playing: true, silent: limit * 4)

        #expect(past.verdict == .notCapturing)
        #expect(past.silentWhilePlaying > limit)
    }

    // MARK: - The guarantee

    /// Restated as one property: nothing but a sample can prove the tap, and
    /// nothing but audible evidence can condemn it.
    @Test(arguments: [0.0, 1.0, 10.0, 600.0])
    func onlyPlaybackCanCondemnATap(silent: TimeInterval) {
        #expect(evaluate(playing: false, silent: silent).verdict != .notCapturing)
    }

    // MARK: - What counts as playing

    private let own: AudioObjectID = 1
    private func playing(
        _ id: AudioObjectID, _ bundleID: String? = nil, capturing: Bool = false
    ) -> CaptureProof.PlayingProcess {
        CaptureProof.PlayingProcess(id: id, isCapturing: capturing, bundleID: bundleID)
    }

    @Test func anotherAppPlayingIsEvidence() {
        #expect(
            CaptureProof.isOtherAudioPlaying(
                [playing(2, "com.apple.Music")], ownProcess: own))
    }

    @Test func coreEQsOwnPlaybackIsNotEvidence() {
        #expect(!CaptureProof.isOtherAudioPlaying([playing(own)], ownProcess: own))
        #expect(!CaptureProof.isOtherAudioPlaying([], ownProcess: own))
    }

    /// The defect: with only an excluded app playing, the silent tap was
    /// judged not capturing, and CoreEQ said it was not processing audio.
    @Test func anExcludedAppPlayingIsNotEvidence() {
        #expect(
            !CaptureProof.isOtherAudioPlaying(
                [playing(2, "com.colliderli.iina")], ownProcess: own,
                ignoringApps: ["com.colliderli.iina"]))
    }

    /// Identifiers are compared without case: the stored list comes from the
    /// app's bundle, the process's from Core Audio, and nothing promises the
    /// two spell it alike.
    @Test func anExcludedAppIsRecognisedInAnyCase() {
        #expect(
            !CaptureProof.isOtherAudioPlaying(
                [playing(2, "com.apple.QuickTimePlayerX")], ownProcess: own,
                ignoringApps: ["com.apple.quicktimeplayerx"]))
    }

    /// Excluding one app says nothing about the rest.
    @Test func anotherAppBesideAnExcludedOneIsEvidence() {
        #expect(
            CaptureProof.isOtherAudioPlaying(
                [playing(2, "com.colliderli.iina"), playing(3, "com.spotify.client")],
                ownProcess: own, ignoringApps: ["com.colliderli.iina"]))
    }

    /// A process whose identifier could not be read is counted: an unknown
    /// player is still a player.
    @Test func aProcessWithoutAnIdentifierIsEvidence() {
        #expect(
            CaptureProof.isOtherAudioPlaying(
                [playing(2)], ownProcess: own, ignoringApps: ["com.colliderli.iina"]))
    }

    @Test func aRecorderIsLeftOutOnlyWhenAsked() {
        let recorder = [playing(2, "com.apple.QuickTimePlayerX", capturing: true)]
        #expect(
            !CaptureProof.isOtherAudioPlaying(recorder, ownProcess: own, ignoringCapturing: true))
        #expect(CaptureProof.isOtherAudioPlaying(recorder, ownProcess: own))
    }

    /// The whole defect end to end: a fresh tap, nothing received, only an
    /// excluded app playing, for far longer than the limit. It must keep
    /// waiting, never conclude it is not capturing.
    @Test func aTapSilentWhileOnlyExcludedAppsPlayIsNeverCalledBroken() {
        let onlyExcluded = CaptureProof.isOtherAudioPlaying(
            [playing(own), playing(2, "com.colliderli.iina")], ownProcess: own,
            ignoringCapturing: true, ignoringApps: ["com.colliderli.iina"])
        var silent: TimeInterval = 0
        for _ in 0..<Int(limit * 10 / interval) {
            let result = evaluate(playing: onlyExcluded, silent: silent)
            #expect(result.verdict == .waiting)
            silent = result.silentWhilePlaying
        }
    }
}
