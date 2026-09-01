import Darwin
import Foundation

/// One IO cycle, as the render thread saw it.
///
/// Deliberately raw. Nothing here is a conclusion: the cadence of these records
/// *is* the device's real sample rate, and working that out is done afterwards,
/// on the main thread, with hindsight and no deadline.
struct RateCycle: Equatable {
    /// `mach_absolute_time` units, taken from the IO proc's own timestamp.
    var hostTime: UInt64
    /// The device's sample clock. Zero when Core Audio did not mark it valid.
    var sampleTime: Double
    /// Frames the device asked for this cycle.
    var frames: Int
    /// The rate the filters were designed for while this cycle ran. The whole
    /// point of the trace is the interval where this disagrees with the cadence
    /// of `hostTime`.
    var configuredRate: Double
}

/// Something that happened to the rate, and when.
///
/// The kind is an enum and not a string on purpose. These are written from the
/// render thread, and a `String` field would mean a retain on the way in and a
/// release of whatever it replaced on the way out — ARC traffic on the audio
/// path, to say something no faster than a tag does. Words are attached later.
struct RateEvent: Equatable {
    enum Kind: Equatable {
        /// Core Audio said the device's nominal rate changed.
        case listenerFired
        /// The new rate was read back and staged for the render thread.
        case rateStaged
        /// The render thread picked it up. The far edge of the stale window.
        case coefficientsRecomputed
    }

    var hostTime: UInt64
    var kind: Kind
    /// The rate the event is about, or zero when it is not about one.
    var rate: Double
}

/// A flight recorder for sample-rate changes.
///
/// A Bluetooth headset moving to its call profile drops the output rate by two
/// to three times. Coefficients are a function of `2πf/fs`, so until they are
/// recomputed every band sits at the wrong frequency — a 1 kHz bell lands near
/// 333 Hz. CoreEQ recomputes them from a property listener, and a listener
/// necessarily fires *after* the change, so a window exists. Whether it is two
/// buffers or three hundred milliseconds decides whether it is worth fixing,
/// and that is not answerable by reading the source.
///
/// So this measures rather than decides. The render thread writes one small
/// record per cycle into a fixed ring and never looks at it; the main thread
/// marks the moments it knows about; the arithmetic happens later. Building a
/// detector first would mean choosing thresholds before having any data to
/// choose them from.
///
/// `@unchecked Sendable` on the same terms as `EQProcessor`: one writer on the
/// render thread, one reader on the main thread, fixed storage allocated up
/// front, and no lock anywhere on the audio path. A torn record costs one line
/// of a diagnostic.
final class RateTrace: @unchecked Sendable {

    /// About five seconds at a 512-frame buffer, which is far longer than any
    /// route change takes and still only 24 KB.
    static let capacity = 512
    private static let eventCapacity = 32

    /// Host ticks per second, from the machine's own timebase — 125/3 on Apple
    /// silicon, so this cannot be assumed to be nanoseconds.
    static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    nonisolated(unsafe) private var cycles = [RateCycle](
        repeating: RateCycle(hostTime: 0, sampleTime: 0, frames: 0, configuredRate: 0),
        count: capacity)
    nonisolated(unsafe) private var written = 0

    nonisolated(unsafe) private var events = [RateEvent](
        repeating: RateEvent(hostTime: 0, kind: .listenerFired, rate: 0), count: eventCapacity)
    nonisolated(unsafe) private var eventsWritten = 0

    /// Called once per IO cycle, on the render thread.
    ///
    /// Four stores into storage that already exists. No allocation, no lock, no
    /// retain: `RateCycle` is trivial, and the array is never resized.
    func record(hostTime: UInt64, sampleTime: Double, frames: Int, configuredRate: Double) {
        cycles[written % Self.capacity] = RateCycle(
            hostTime: hostTime,
            sampleTime: sampleTime,
            frames: frames,
            configuredRate: configuredRate)
        written &+= 1
    }

    /// Notes something that happened, from either thread.
    ///
    /// Trivial all the way down, so the render thread can call it: two stores
    /// into storage that already exists, and `mach_absolute_time` is a bare
    /// register read.
    func mark(_ kind: RateEvent.Kind, rate: Double = 0, at hostTime: UInt64 = mach_absolute_time())
    {
        events[eventsWritten % Self.eventCapacity] = RateEvent(
            hostTime: hostTime, kind: kind, rate: rate)
        eventsWritten &+= 1
    }

    /// Everything still in the ring, oldest first. Main thread.
    func snapshot() -> (cycles: [RateCycle], events: [RateEvent]) {
        let cycleCount = min(written, Self.capacity)
        let cycleStart = written - cycleCount
        let recorded = (0..<cycleCount).map { cycles[(cycleStart + $0) % Self.capacity] }

        let eventCount = min(eventsWritten, Self.eventCapacity)
        let eventStart = eventsWritten - eventCount
        let marked = (0..<eventCount).map { events[(eventStart + $0) % Self.eventCapacity] }

        return (recorded, marked)
    }
}
