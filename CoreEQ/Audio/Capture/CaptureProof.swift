import CoreAudio
import Foundation

/// Whether a tap has shown it can capture, and what to conclude when it has
/// not.
///
/// Pure, and its own type, because the judgement is the hard part and the
/// engine it belongs to cannot be reached by a test. Reading a sample and
/// asking whether anything is playing are three lines of Core Audio each;
/// deciding what those two facts mean together is where this has been wrong.
enum CaptureProof {

    enum Verdict: Equatable {
        /// The tap delivered audio. Mute, and start processing.
        case proven
        /// Nothing yet, and nothing to conclude from it.
        case waiting
        /// Audio is playing and none of it is arriving.
        case notCapturing
    }

    /// - Parameters:
    ///   - hasReceivedAudio: whether the tap has delivered a non-zero sample.
    ///   - isAnythingPlaying: whether any *other* process is playing output.
    ///   - silentWhilePlaying: how long the tap has been silent while something
    ///     was playing, accumulated across previous evaluations.
    ///   - interval: how long since the last evaluation.
    ///   - limit: how long that may go on before saying the tap is not
    ///     capturing.
    /// - Returns: the verdict, and the silence to carry into the next
    ///   evaluation.
    ///
    /// Silence on its own is never enough. A quiet Mac is quiet, and an engine
    /// that reads that as a refused permission accuses people of something they
    /// did not do — which is what the first version of this did, on every launch
    /// where nothing happened to be playing. Only silence *while audio is
    /// demonstrably flowing* means the tap is not receiving, so the clock only
    /// runs while something is playing and is reset when nothing is.
    static func evaluate(
        hasReceivedAudio: Bool,
        isAnythingPlaying: Bool,
        silentWhilePlaying: TimeInterval,
        interval: TimeInterval,
        limit: TimeInterval
    ) -> (verdict: Verdict, silentWhilePlaying: TimeInterval) {
        if hasReceivedAudio {
            return (.proven, 0)
        }
        guard isAnythingPlaying else {
            return (.waiting, 0)
        }
        let silent = silentWhilePlaying + interval
        return (silent >= limit ? .notCapturing : .waiting, silent)
    }

    // MARK: - What counts as playing

    /// A process sending output, as much as `isOtherAudioPlaying` needs.
    ///
    /// `isCapturing` and `bundleID` are read only when the question asks about
    /// them, so a reader that was not asked leaves them false and nil.
    struct PlayingProcess: Equatable, Sendable {
        let id: AudioObjectID
        var isCapturing = false
        var bundleID: String?
    }

    /// Whether anything in `playing` is evidence that audio is flowing past
    /// the tap.
    ///
    /// - Parameters:
    ///   - playing: the processes sending output right now.
    ///   - ownProcess: CoreEQ's own process, whose playback is not evidence of
    ///     anything reaching the tap.
    ///   - ignoringCapturing: leave out processes also capturing input —
    ///     recorders and call apps, which can hold output open while sending
    ///     nothing. Measured: QuickTime recording shows as running output.
    ///   - ignoringApps: the apps the tap leaves out, by bundle identifier,
    ///     in any case. Their sound never reaches the tap by design, and
    ///     counting it called a working tap broken: with only an excluded app
    ///     playing, CoreEQ said it was not processing audio.
    /// - Returns: whether any process left after those is playing.
    static func isOtherAudioPlaying(
        _ playing: [PlayingProcess],
        ownProcess: AudioObjectID,
        ignoringCapturing: Bool = false,
        ignoringApps: Set<String> = []
    ) -> Bool {
        let ignored = Set(ignoringApps.map { $0.lowercased() })
        return playing.contains { process in
            if process.id == ownProcess { return false }
            if ignoringCapturing && process.isCapturing { return false }
            if let bundleID = process.bundleID, ignored.contains(bundleID.lowercased()) {
                return false
            }
            return true
        }
    }
}
