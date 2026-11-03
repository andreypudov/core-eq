import Foundation
import Testing

/// When the audio path may be torn down, and when it must not be.
///
/// The upside of getting this right is a Mac that sleeps. The downside of
/// getting it wrong is the defect this app has already shipped three times: no
/// sound, and every layer reporting success. So the rules that protect against
/// that are stated first, and stated as rules rather than as examples.
struct IdlePolicyTests {

    private func verdict(
        isRunning: Bool = true,
        silentSeconds: TimeInterval = 0,
        isAnythingPlaying: Bool = false,
        isEnabled: Bool = true,
        isCaptureProven: Bool = true,
        pausesWhenSilent: Bool = true,
        isRecovering: Bool = false,
        stepsAsideForRecording: Bool = false,
        isOutputHeld: Bool = false
    ) -> IdlePolicy.Verdict {
        IdlePolicy.evaluate(
            isRunning: isRunning, silentSeconds: silentSeconds,
            isAnythingPlaying: isAnythingPlaying, isEnabled: isEnabled,
            isCaptureProven: isCaptureProven, pausesWhenSilent: pausesWhenSilent,
            isRecovering: isRecovering,
            stepsAsideForRecording: stepsAsideForRecording, isOutputHeld: isOutputHeld)
    }

    // MARK: - A device another process holds

    /// A player taking the device runs it, which is what a player wanting
    /// equalizing does too. Waking for it stalled the player's start by fourteen
    /// seconds, measured with `make hog-test`.
    @Test func aHeldOutputIsNeverResumedFor() {
        #expect(verdict(isRunning: false, isAnythingPlaying: true, isOutputHeld: true) == .stayIdle)
        #expect(
            verdict(isRunning: false, pausesWhenSilent: false, isOutputHeld: true) == .stayIdle,
            "turning idling off pins the engine on, which is no reason to fight for the device")
    }

    @Test func aRunningPathIsNotStoppedBecauseItsOutputIsHeld() {
        #expect(
            verdict(isRunning: true, isAnythingPlaying: true, isOutputHeld: true) == .keepRunning)
    }

    @Test func theOutputComingBackAllowsAResume() {
        #expect(verdict(isRunning: false, isAnythingPlaying: true, isOutputHeld: false) == .resume)
    }

    // MARK: - Recording

    /// Rendering while a recording captures system audio doubles every sound
    /// in it, so the path goes even with audio playing.
    @Test func aRecordingReleasesThePathWhileAudioPlays() {
        #expect(
            verdict(isAnythingPlaying: true, stepsAsideForRecording: true) == .goIdle)
    }

    /// Playback during the recording must not bring the path back.
    @Test func playbackDoesNotResumeDuringARecording() {
        #expect(
            verdict(
                isRunning: false, isAnythingPlaying: true,
                stepsAsideForRecording: true) == .stayIdle)
    }

    /// The recording ending is what brings the equalizer back.
    @Test func theEqualizerReturnsWhenTheRecordingEnds() {
        #expect(verdict(isRunning: false, isAnythingPlaying: true) == .resume)
    }

    /// Its own setting, so switching idling off does not switch this off too.
    @Test func aRecordingIsSteppedAsideForEvenWithIdlingOff() {
        #expect(
            verdict(isAnythingPlaying: true, pausesWhenSilent: false, stepsAsideForRecording: true)
                == .goIdle)
    }

    /// An unproven tap is not muting, so there is no copy to remove — and the
    /// path is needed to prove it.
    @Test func anUnprovenTapIsKeptThroughARecording() {
        #expect(
            verdict(isCaptureProven: false, stepsAsideForRecording: true) == .keepRunning)
    }

    /// A path that failed stays with its retry, recording or not.
    @Test func aFailedPathIsNotTouchedForARecording() {
        #expect(
            verdict(isRunning: false, isRecovering: true, stepsAsideForRecording: true)
                == .stayIdle)
    }

    // MARK: - What must never happen

    /// Audio is arriving. Nothing below may tear the path down under it.
    @Test func aPathCarryingAudioIsNeverTornDown() {
        for silent in [0.0, 0.5, 5, 29, 29.999] {
            #expect(verdict(silentSeconds: silent) == .keepRunning, "torn down after \(silent)s")
        }
    }

    /// Before the tap has been proved, silence is not evidence of quiet — it is
    /// equally the sound of a refused permission. Idling on it would tear down
    /// the path that has to run for the answer to arrive, and the engine would
    /// never learn anything.
    @Test func anUnprovenTapIsNeverIdled() {
        #expect(verdict(silentSeconds: 600, isCaptureProven: false) == .keepRunning)
    }

    /// The user's switch wins over every rule. Every silent-Mac defect in this
    /// app's history had no workaround from inside the app; this one does, and
    /// it has to hold in both directions.
    @Test func theSettingOverridesEveryOtherRule() {
        #expect(verdict(silentSeconds: 9_999, pausesWhenSilent: false) == .keepRunning)
        #expect(
            verdict(isRunning: false, isAnythingPlaying: false, pausesWhenSilent: false) == .resume)
    }

    /// A path that cannot be built must not be built twice a second.
    ///
    /// Found by testing on hardware, not by reading: after a resume that fails,
    /// the engine is neither running nor idle, so the resume rule fires again on
    /// the next poll, and an output device the engine refuses would be retried
    /// at the poll interval for as long as the app ran. Recovery belongs to the
    /// retry that already has a backoff and a ceiling.
    @Test func aFailedPathIsLeftToItsOwnRetry() {
        #expect(verdict(isRunning: false, isAnythingPlaying: true, isRecovering: true) == .stayIdle)
        #expect(verdict(silentSeconds: 600, isRecovering: true) == .keepRunning)
    }

    // MARK: - Going idle

    /// The point of the whole thing: after long enough silence, let go of the
    /// device so the machine can sleep.
    @Test func longSilenceReleasesTheDevice() {
        #expect(verdict(silentSeconds: 30) == .goIdle)
        #expect(verdict(silentSeconds: 600) == .goIdle)
    }

    /// A process holding the device open while sending zeros is the state where
    /// the two signals disagree. Measured on this machine the system signal is
    /// clean — nothing reports output while nothing plays — but the engine must
    /// not depend on that, because the consequence of trusting it is a rebuild
    /// every thirty seconds.
    @Test func silenceAloneDoesNotIdleWhileSomethingHoldsTheDevice() {
        #expect(verdict(silentSeconds: 600, isAnythingPlaying: true) == .keepRunning)
    }

    /// Switched off there is nothing to process, so the device is released at
    /// once rather than after the silence timer — the audio path would exist
    /// only to pass audio through untouched.
    @Test func beingSwitchedOffReleasesTheDeviceImmediately() {
        #expect(verdict(silentSeconds: 0, isEnabled: false) == .goIdle)
    }

    /// The threshold is a floor, not a window: it does not stop being true.
    @Test func theVerdictIsStableOnceSilenceIsLongEnough() {
        var seconds = 30.0
        while seconds < 10_000 {
            #expect(verdict(silentSeconds: seconds) == .goIdle)
            seconds *= 2
        }
    }

    // MARK: - Coming back

    /// The one signal available while idle: the render path is gone, so the
    /// system has to be asked.
    @Test func somethingPlayingBringsThePathBack() {
        #expect(verdict(isRunning: false, isAnythingPlaying: true) == .resume)
    }

    @Test func aQuietMacStaysIdle() {
        #expect(verdict(isRunning: false, isAnythingPlaying: false) == .stayIdle)
    }

    /// Switched off, there is nothing to come back for even when audio plays.
    /// Resuming would build the whole path to pass audio through unchanged, and
    /// take the assertion back with it.
    @Test func playbackWhileSwitchedOffDoesNotResume() {
        #expect(verdict(isRunning: false, isAnythingPlaying: true, isEnabled: false) == .stayIdle)
    }

    /// Silence measured before the teardown says nothing about the world after
    /// it, and must not keep the engine from coming back.
    @Test func staleSilenceDoesNotBlockAResume() {
        #expect(
            verdict(isRunning: false, silentSeconds: 9_999, isAnythingPlaying: true) == .resume)
    }

    // MARK: - Stability

    /// A verdict has to be a function of the state, not of the order states
    /// arrived in: the same inputs twice give the same answer, so the engine
    /// cannot be walked into oscillating by an unlucky sequence.
    @Test func theSameStateAlwaysGivesTheSameVerdict() {
        for running in [true, false] {
            for silent in [0.0, 29, 30, 120] {
                for playing in [true, false] {
                    for enabled in [true, false] {
                        let first = verdict(
                            isRunning: running, silentSeconds: silent,
                            isAnythingPlaying: playing, isEnabled: enabled)
                        let second = verdict(
                            isRunning: running, silentSeconds: silent,
                            isAnythingPlaying: playing, isEnabled: enabled)
                        #expect(first == second)
                    }
                }
            }
        }
    }

    /// Idling and resuming must not both be true of one moment. Silence is
    /// measured by the render path and playback by the system, and the two can
    /// disagree — a process can hold the device open while sending zeros. If
    /// that disagreement produced "go idle" and "resume" in turn, the engine
    /// would rebuild the audio path several times a second forever.
    @Test func noStateBothIdlesAndResumes() {
        for silent in [0.0, 30, 600] {
            let running = verdict(isRunning: true, silentSeconds: silent, isAnythingPlaying: true)
            guard running == .goIdle else { continue }
            let idle = verdict(isRunning: false, silentSeconds: silent, isAnythingPlaying: true)
            #expect(idle != .resume, "silence says idle while playback says resume: it will thrash")
        }
    }
}
