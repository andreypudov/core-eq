import CoreAudio
import Foundation

/// What the render thread noticed, for whoever asks later.
///
/// None of this changes a sample. It exists because the render thread is the
/// only place several questions can be answered at all — whether the tap is
/// delivering anything, whether the chain is producing more than fits, how long
/// the room has been quiet — and every one of them turned out to be the fact
/// that settled a real defect. Kept together because they share a rule that
/// nothing else in the processor shares: written on the audio thread, read from
/// the main one, and deliberately unsynchronised.
///
/// That rule is safe for exactly these fields and would not be for the audio
/// state. Each is a single word, written by one thread and read by another that
/// only ever draws a report with it; a reader that catches a stale value asks
/// again a moment later and gets the new one. A lock on every block would cost
/// more than the facts are worth, and a lock on the audio thread is the thing
/// the whole design is arranged to avoid.
struct RenderObservations {

    /// Whether the tap has ever delivered anything but digital silence.
    ///
    /// It exists because a tap can be created without permission. It reports a
    /// plausible format, the aggregate runs, the IO proc fires — and every
    /// sample is zero, while `muteBehavior` silences every other process at the
    /// hardware. Nothing in the Core Audio API tells that apart from a Mac that
    /// happens to be quiet, so the engine watches for it instead.
    var hasReceivedAudio = false

    /// How long the tap has delivered nothing but digital zero.
    ///
    /// Reset by the first non-zero sample, so it measures the *current* run of
    /// silence rather than a total. `IdlePolicy` uses it to decide when the
    /// audio path can be released — which is why it counts exact zeros and not
    /// "quiet": a passage at -60 dB is still someone listening, and stopping
    /// under them is the failure that matters here.
    var silentSeconds: Double = 0

    /// The loudest sample the EQ has produced since the engine started, and how
    /// many left the representable range.
    ///
    /// A boosted preset can ask for more headroom than the signal has, and the
    /// result is distortion the user hears as noise rather than as loudness.
    /// Nothing else can settle it: the mix level arriving at a tap is unknowable
    /// from inside it, so the only way to know whether CoreEQ is clipping is to
    /// look at what CoreEQ produced.
    var peakLevel: Float = 0
    var clippedSamples = 0

    /// Loudest sample the chain was *handed*, this block and this session.
    ///
    /// Without it the output peak cannot be attributed. The system mix is
    /// Float32 and is not clamped before a tap sees it, so audio can arrive
    /// above full scale on its own — and at Flat, where every band is identity
    /// and the trim is unity, CoreEQ passes it through bit for bit. Counting
    /// that as clipping blamed the app for the material, and told the user to
    /// lower a preamp that Auto had disabled.
    var blockSourcePeak: Float = 0
    var sourcePeakLevel: Float = 0

    /// Forgets everything. Called when the engine starts, because every one of
    /// these is a claim about the audio path that is now being rebuilt.
    mutating func reset() {
        hasReceivedAudio = false
        silentSeconds = 0
        peakLevel = 0
        clippedSamples = 0
        blockSourcePeak = 0
        sourcePeakLevel = 0
    }

    /// The level this block was handed, from `BufferRouter.place`.
    mutating func note(sourcePeak: Float) {
        blockSourcePeak = sourcePeak
        if sourcePeak > sourcePeakLevel { sourcePeakLevel = sourcePeak }
    }

    /// Notes a block of input: whether it carried anything, and how much time
    /// passed if it did not.
    mutating func observe(input: UnsafeMutableAudioBufferListPointer, seconds: Double) {
        let signal = Self.carriesSignal(input)
        if signal {
            hasReceivedAudio = true
            silentSeconds = 0
        } else {
            silentSeconds += seconds
        }
    }

    /// Notes what the chain produced on one channel.
    ///
    /// The peak is kept for the life of the engine rather than per block — the
    /// question is whether this ever happened, and a value that decays answers
    /// it only for whoever is watching at the time.
    mutating func observe(output samples: UnsafePointer<Float>, stride: Int, frames: Int) {
        // What counts as ours. Above full scale, and above what arrived: a
        // sample the chain did not lift past the ceiling is the material's to
        // answer for, not the app's, and saying otherwise sends the user after
        // a control that will not help.
        let ceiling = max(1.0, blockSourcePeak)
        var peak = peakLevel
        var clipped = 0
        var index = 0
        for _ in 0..<frames {
            let magnitude = abs(samples[index])
            if magnitude > peak { peak = magnitude }
            if magnitude > ceiling { clipped &+= 1 }
            index += stride
        }
        peakLevel = peak
        clippedSamples &+= clipped
    }

    /// Whether any buffer holds a sample that is not zero.
    ///
    /// Stops at the first one, so on a Mac that is playing this costs a single
    /// comparison.
    private static func carriesSignal(_ abl: UnsafeMutableAudioBufferListPointer) -> Bool {
        for i in 0..<abl.count {
            guard let data = abl[i].mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            let count = Int(abl[i].mDataByteSize) / MemoryLayout<Float>.size
            for sample in 0..<count where data[sample] != 0 {
                return true
            }
        }
        return false
    }
}
