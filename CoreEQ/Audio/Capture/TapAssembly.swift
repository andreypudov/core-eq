import CoreAudio
import Foundation

/// One tap that was created, as the assembly sees it.
struct AssembledTap: Equatable {
    var id: AudioObjectID
    var uuid: UUID
    /// Channels this tap delivers.
    var channels: Int
    /// Output stream it is bound to, or -1 for the stereo global tap.
    var stream: Int
    /// Whether this tap took a device stream's format, rather than being a
    /// stereo mixdown of the whole device.
    var isDeviceBound: Bool
    /// Global output channel this tap's channel 0 feeds. Zero for a single tap;
    /// the running total of earlier streams when there are several.
    var firstChannel: Int = 0
}

/// The tap could not be created.
///
/// Its own type because it is the one failure that means the permission was
/// refused, and the only one the Settings pane may describe that way.
struct TapUnavailable: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "CoreEQ could not capture system audio (OSStatus \(status)). Check that "
            + "System Audio Recording is allowed in Privacy & Security."
    }
}

/// The tap delivered samples the render path cannot read.
struct UnrenderableTapFormat: Error, LocalizedError {
    var errorDescription: String? {
        "The audio tap did not deliver 32-bit float samples, which is the "
            + "only format CoreEQ renders."
    }
}

/// Creating and destroying taps.
///
/// A protocol so that `TapAssembly`'s decisions — how many taps a device needs,
/// what to do when only some of them can be made, when to give up and take a
/// stereo mixdown instead — can be tested without the hardware that provokes
/// them. Those decisions are the part that has been wrong; the Core Audio calls
/// underneath are four lines each.
@MainActor
protocol TapFactory {
    /// A tap bound to one output stream, taking that stream's format.
    func makeDeviceBoundTap(stream: Int) throws -> AssembledTap
    /// The stereo mixdown of everything, which every device can provide.
    func makeGlobalTap() throws -> AssembledTap
    func destroy(_ tap: AssembledTap)
}

@MainActor
enum TapAssembly {
    /// The taps a device needs, created.
    ///
    /// A tap binds to one stream and takes that stream's format, so a device
    /// presenting its channels as several streams needs one tap each. Binding to
    /// the widest alone captures that stream and abandons the rest, which on an
    /// interface presenting eight stereo streams is fourteen of sixteen
    /// channels.
    ///
    /// Three attempts, narrowing: one tap per stream, then the widest single
    /// stream, then the stereo mixdown. Only the last is required to work.
    static func taps(
        forStreams streams: [Int], using factory: any TapFactory
    ) throws
        -> [AssembledTap]
    {
        if streams.count > 1, streams.allSatisfy({ $0 > 0 }) {
            var taps: [AssembledTap] = []
            var offset = 0
            for (index, channels) in streams.enumerated() {
                guard var tap = try? factory.makeDeviceBoundTap(stream: index) else { break }
                tap.firstChannel = offset
                taps.append(tap)
                offset += channels
            }
            if taps.count == streams.count {
                return taps
            }
            // Partial success is not a usable device: the streams that did tap
            // would be muted and replaced while the rest played on untouched, so
            // some of the audio would be equalized and some would not.
            for tap in taps { factory.destroy(tap) }
        }

        if let tap = try? factory.makeDeviceBoundTap(stream: OutputPlan.widestStream(of: streams)) {
            return [tap]
        }

        // The mixdown loses everything past two channels, which is why it is
        // last, and keeps audio working on a device the others could not serve,
        // which is why it exists.
        return [try factory.makeGlobalTap()]
    }
}
