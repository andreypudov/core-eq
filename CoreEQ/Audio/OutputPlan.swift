import CoreAudio
import Foundation

/// What the engine learned about a device and its tap, reduced to plain values.
///
/// This exists to separate the *decision* from the *querying*. Reading a device
/// needs Core Audio and real hardware, so it cannot be tested here; choosing
/// where each tap channel goes needs neither, and choosing is where every audio
/// defect in this app has actually been. Everything below is pure.
struct DeviceDescription: Equatable {
    /// Channels the tap will deliver.
    var tapChannels: Int
    /// Whether the tap took the device stream's format, rather than being a
    /// stereo mixdown of it.
    var isDeviceBound: Bool
    /// Total output channels the device presents, across all its buffers.
    var deviceChannels: Int
    /// The device's own stereo pair, zero-based, or nil when it does not say.
    var preferredStereo: StereoPair?

    init(
        tapChannels: Int, isDeviceBound: Bool, deviceChannels: Int,
        preferredStereo: StereoPair? = nil
    ) {
        self.tapChannels = tapChannels
        self.isDeviceBound = isDeviceBound
        self.deviceChannels = deviceChannels
        self.preferredStereo = preferredStereo
    }
}

/// Two channel numbers, zero-based.
struct StereoPair: Equatable {
    var left: Int
    var right: Int
}

enum OutputPlan {
    /// Where to send each tap channel.
    ///
    /// A device-bound tap took the device stream's format, so channel *i* is
    /// channel *i* — nothing is mixed down and nothing needs placing. A stereo
    /// mixdown has to be told where the device keeps its pair, which the Core
    /// Audio header is explicit need not be the first two channels; every other
    /// channel then stays silent.
    static func layout(for description: DeviceDescription) -> EQProcessor.OutputLayout {
        guard description.isDeviceBound else {
            let pair = stereo(for: description)
            return EQProcessor.OutputLayout(
                tapChannels: 2, destinations: [pair.left, pair.right])
        }
        let channels = max(0, description.tapChannels)
        return EQProcessor.OutputLayout(
            tapChannels: channels, destinations: Array(0..<channels))
    }

    /// The stereo pair to place a mixdown into.
    ///
    /// Falls back to the first two channels both when the device declines to say
    /// — an HDMI display tested here does exactly that — and when what it says
    /// does not fit the channels it actually has, which would otherwise route
    /// audio into nothing.
    static func stereo(for description: DeviceDescription) -> StereoPair {
        let fallback = StereoPair(left: 0, right: 1)
        guard let pair = description.preferredStereo else { return fallback }
        guard pair.left >= 0, pair.right >= 0,
            pair.left < description.deviceChannels, pair.right < description.deviceChannels
        else { return fallback }
        return pair
    }

    /// Which output stream to bind a device-bound tap to.
    ///
    /// A device can present several output streams, and the tap binds to exactly
    /// one. This picks the widest: the stream carrying the most channels is the
    /// device's main output, and binding to a narrower one would leave the rest
    /// of the device silent. Ties go to the earliest, which is the device's own
    /// ordering. An empty list means the device reported no streams, and stream
    /// 0 is the only thing left to try.
    static func widestStream(of channelCounts: [Int]) -> Int {
        var best = 0
        var bestChannels = -1
        for (index, channels) in channelCounts.enumerated() where channels > bestChannels {
            best = index
            bestChannels = channels
        }
        return best
    }
}
