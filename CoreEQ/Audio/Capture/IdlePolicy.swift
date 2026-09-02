import Foundation

/// Whether the audio path should be running at all.
///
/// A started aggregate device makes coreaudiod hold a
/// `PreventUserIdleSystemSleep` assertion on CoreEQ's behalf. That is correct
/// while audio is playing and wrong afterwards: measured, Core Audio spins the
/// IO context up on the first sound and never spins it back down, so a Mac that
/// played something once at breakfast is still being held awake at midnight.
/// The assertion is released by `AudioDeviceStop` alone.
///
/// So the rule is: stop when there is demonstrably nothing to do, and come back
/// the moment there is. This decides both, and does so as a pure function
/// because the cost of getting it wrong is the failure this app has shipped
/// three times — a Mac producing no sound while every layer reports success.
/// A rule that can be tested against a hundred invented sequences is worth more
/// than one that can only be tested by playing music and waiting.
enum IdlePolicy {

    /// What the engine should do next.
    enum Verdict: Equatable {
        case keepRunning
        /// Tear the audio path down, releasing the device and the assertion.
        case goIdle
        case stayIdle
        /// Build it again, because something wants to play.
        case resume
    }

    /// Silence that means nothing is playing, rather than a gap between tracks.
    ///
    /// Thirty seconds is long enough that no pause inside listening reaches it —
    /// a gap between albums, a paused video someone comes back to — and short
    /// enough that a machine left alone still sleeps on schedule. It is also
    /// well past the point where a rebuild's 27 ms could be noticed.
    static let idleAfter: TimeInterval = 30

    /// - Parameters:
    ///   - isRunning: whether the audio path exists right now.
    ///   - silentSeconds: how long the render path has seen nothing but digital
    ///     zero. Meaningless while not running, and ignored there.
    ///   - isAnythingPlaying: whether any other process is playing output. The
    ///     only signal available while idle, since the render path is gone.
    ///   - isEnabled: whether the user has CoreEQ switched on at all.
    ///   - isCaptureProven: whether a tap has been seen delivering audio.
    ///   - pausesWhenSilent: the user's setting. False pins the engine on.
    ///   - isAudioStarting: whether something has just announced itself as about
    ///     to use audio, which arrives slightly before it plays.
    ///   - isRecovering: whether the last attempt to build the path failed.
    ///   - idleAfter: the silence that counts as nothing playing.
    /// - Returns: what to do.
    static func evaluate(
        isRunning: Bool,
        silentSeconds: TimeInterval,
        isAnythingPlaying: Bool,
        isEnabled: Bool,
        isCaptureProven: Bool,
        pausesWhenSilent: Bool,
        isAudioStarting: Bool = false,
        isRecovering: Bool = false,
        idleAfter: TimeInterval = idleAfter
    ) -> Verdict {
        // A path that cannot be built is not a path that should be built twice a
        // second. When the last attempt failed, recovery belongs to the retry
        // that already owns it — with its own backoff and its own limit — and
        // this must keep its hands off. Without this, an output device the
        // engine refuses would be retried at the poll interval forever, which is
        // the same fault as a retry loop with no ceiling.
        guard !isRecovering else { return isRunning ? .keepRunning : .stayIdle }

        // The escape hatch, and the first thing checked. Every silent-Mac defect
        // in this app's history had no workaround from inside the app; this one
        // has a switch, and the switch has to win over every rule below it.
        guard pausesWhenSilent else { return isRunning ? .keepRunning : .resume }

        guard isRunning else {
            // Switched off, there is nothing to come back for: the audio path
            // would be built only to pass audio through untouched.
            guard isEnabled else { return .stayIdle }
            // `isAudioStarting` is deliberately enough on its own. The device
            // needs about 90 ms to deliver its first buffer after being
            // started, and a process announcing itself arrives about 80 ms
            // before it plays — so acting on the announcement is what turns a
            // gap of unequalized audio into no gap at all. Being wrong costs
            // one idle period, which is thirty seconds of a device nobody is
            // using; being late costs audio the user hears.
            return (isAnythingPlaying || isAudioStarting) ? .resume : .stayIdle
        }

        // Switched off is the clearest case there is — no audio is being
        // processed, so nothing is lost by releasing the device at once.
        guard isEnabled else { return .goIdle }

        // Silence is only evidence when the tap is known to deliver. Before that
        // it is equally the sound of a permission that was refused, and idling
        // on it would tear down the very path that has to run to find out.
        guard isCaptureProven else { return .keepRunning }

        // Both signals have to agree, and that is not belt and braces — it is
        // what stops the engine oscillating. Silence is measured by the render
        // path and playback by the system, and they can disagree: a process is
        // free to hold the device open while sending nothing but zeros. Idling
        // on silence alone would then meet a resume on playback alone, and the
        // audio path would be rebuilt every thirty seconds for as long as that
        // process ran. Requiring both makes `goIdle` and `resume` impossible to
        // reach from the same state.
        //
        // The cost is that an app which never lets go of the device keeps the
        // Mac awake. That is exactly today's behaviour, so the conservative
        // failure is no worse than no fix at all — which is the right direction
        // to fail in.
        guard !isAnythingPlaying else { return .keepRunning }

        return silentSeconds >= idleAfter ? .goIdle : .keepRunning
    }
}
