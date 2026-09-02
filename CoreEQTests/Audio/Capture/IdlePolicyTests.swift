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
        isAudioStarting: Bool = false,
        isRecovering: Bool = false
    ) -> IdlePolicy.Verdict {
        IdlePolicy.evaluate(
            isRunning: isRunning, silentSeconds: silentSeconds,
            isAnythingPlaying: isAnythingPlaying, isEnabled: isEnabled,
            isCaptureProven: isCaptureProven, pausesWhenSilent: pausesWhenSilent,
            isAudioStarting: isAudioStarting, isRecovering: isRecovering)
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

    /// Coming back *before* the first sample is the whole point. A process
    /// announcing itself arrives about 80 ms before it plays and the device
    /// needs about 90 ms to start, so waiting for audio to be audible before
    /// reacting is already too late — that is what a second of unequalized
    /// playback was.
    @Test func anAnnouncementIsEnoughToComeBack() {
        let announced = verdict(
            isRunning: false, isAnythingPlaying: false, isAudioStarting: true)
        #expect(announced == .resume)
    }

    /// It is a hint, not an override. Switched off there is still nothing to
    /// come back for, and a failed path is still left to its own retry.
    @Test func anAnnouncementDoesNotOverrideTheRulesAboveIt() {
        #expect(
            verdict(isRunning: false, isEnabled: false, isAudioStarting: true) == .stayIdle)
        #expect(
            verdict(isRunning: false, isAudioStarting: true, isRecovering: true) == .stayIdle)
    }

    /// While running it means nothing — the engine is already up.
    @Test func anAnnouncementDoesNotDisturbARunningEngine() {
        #expect(verdict(silentSeconds: 600, isAudioStarting: true) == .goIdle)
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
