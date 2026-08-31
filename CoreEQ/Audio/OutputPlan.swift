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
    /// Input buffers the device itself presents. Zero for an output-only device.
    var inputBuffers: Int

    init(
        tapChannels: Int, isDeviceBound: Bool, deviceChannels: Int,
        preferredStereo: StereoPair? = nil, inputBuffers: Int = 0
    ) {
        self.tapChannels = tapChannels
        self.isDeviceBound = isDeviceBound
        self.deviceChannels = deviceChannels
        self.preferredStereo = preferredStereo
        self.inputBuffers = inputBuffers
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
        let index = tapBufferIndex(for: description)
        guard description.isDeviceBound else {
            let pair = stereo(for: description)
            return EQProcessor.OutputLayout(
                tapChannels: 2, destinations: [pair.left, pair.right], tapBufferIndex: index)
        }
        let channels = max(0, description.tapChannels)
        return EQProcessor.OutputLayout(
            tapChannels: channels, destinations: Array(0..<channels), tapBufferIndex: index)
    }

    /// Which input buffer of the aggregate carries the tap.
    ///
    /// The aggregate is built from one sub-device and one tap, and Core Audio
    /// lists the sub-device's input buffers before the tap's — so the tap sits
    /// immediately after however many input buffers the output device presents.
    ///
    /// This has to be known rather than searched for. The render path used to
    /// find the tap by matching its channel count, which silently picks the
    /// wrong buffer on any duplex device whose input stream is as wide as the
    /// tap. BlackHole 16ch is exactly that — sixteen in, sixteen out — and the
    /// result was that CoreEQ equalized the device's own silent input while the
    /// tap went on muting every other process: a silent Mac, with the engine
    /// reporting that it was running.
    static func tapBufferIndex(for description: DeviceDescription) -> Int {
        max(0, description.inputBuffers)
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

    /// One tap, and where on the device its channels belong.
    struct TapPlan: Equatable {
        /// Channels this tap delivers — the width of the stream it is bound to.
        var channels: Int
        /// Global output channel that this tap's channel 0 feeds.
        var firstOutputChannel: Int

        init(channels: Int, firstOutputChannel: Int) {
            self.channels = channels
            self.firstOutputChannel = firstOutputChannel
        }
    }

    /// A tap for every output stream, in the device's own stream order.
    ///
    /// A tap binds to exactly one stream and takes that stream's format —
    /// `CATapDescription` offers no way to bind one to a whole device. A device
    /// presenting its sixteen channels as eight stereo streams, which is how
    /// most interfaces present them, therefore needs eight taps; binding to the
    /// widest single stream captures two channels and abandons fourteen.
    static func tapPlans(forStreams channelCounts: [Int]) -> [TapPlan] {
        var plans: [TapPlan] = []
        var offset = 0
        for channels in channelCounts where channels > 0 {
            plans.append(TapPlan(channels: channels, firstOutputChannel: offset))
            offset += channels
        }
        return plans
    }

    /// The layout for a set of taps, laid out in the aggregate's input list
    /// after `inputBuffers` buffers belonging to the device itself.
    ///
    /// Channels are routed in tap order, each tap's own order preserved, so
    /// routed channel *i* is not generally tap channel *i* — which is exactly
    /// why the render path is told both ends.
    static func layout(forTaps taps: [TapPlan], inputBuffers: Int) -> EQProcessor.OutputLayout {
        let firstBuffer = max(0, inputBuffers)
        var destinations: [Int] = []
        var sourceBuffers: [Int] = []
        var sourceChannels: [Int] = []
        for (index, tap) in taps.enumerated() {
            for channel in 0..<max(0, tap.channels) {
                destinations.append(tap.firstOutputChannel + channel)
                sourceBuffers.append(firstBuffer + index)
                sourceChannels.append(channel)
            }
        }
        return EQProcessor.OutputLayout(
            tapChannels: destinations.count,
            destinations: destinations,
            tapBufferIndex: firstBuffer,
            sourceBuffers: sourceBuffers,
            sourceChannels: sourceChannels,
            primaryTapChannels: taps.first?.channels ?? 0)
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

/// Channel roles, as far as a device is willing to describe them.
///
/// Separated from `AudioDevices` for the reason everything else here is: reading
/// a device needs real hardware, but *ordering* the roles a device names is a
/// decision, and decisions are where the defects have been.
enum ChannelRoles {
    /// A bitmap names which roles are present but not their order; Core Audio
    /// lays them out in bit order, which is what this reproduces.
    static func labels(fromBitmap bitmap: AudioChannelBitmap) -> [AudioChannelLabel] {
        let ordered: [(AudioChannelBitmap, AudioChannelLabel)] = [
            (.bit_Left, kAudioChannelLabel_Left),
            (.bit_Right, kAudioChannelLabel_Right),
            (.bit_Center, kAudioChannelLabel_Center),
            (.bit_LFEScreen, kAudioChannelLabel_LFEScreen),
            (.bit_LeftSurround, kAudioChannelLabel_LeftSurround),
            (.bit_RightSurround, kAudioChannelLabel_RightSurround),
            (.bit_LeftCenter, kAudioChannelLabel_LeftCenter),
            (.bit_RightCenter, kAudioChannelLabel_RightCenter),
            (.bit_CenterSurround, kAudioChannelLabel_CenterSurround),
            (.bit_LeftSurroundDirect, kAudioChannelLabel_LeftSurroundDirect),
            (.bit_RightSurroundDirect, kAudioChannelLabel_RightSurroundDirect),
            (.bit_TopCenterSurround, kAudioChannelLabel_TopCenterSurround),
            (.bit_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightLeft),
            (.bit_VerticalHeightCenter, kAudioChannelLabel_VerticalHeightCenter),
            (.bit_VerticalHeightRight, kAudioChannelLabel_VerticalHeightRight),
            (.bit_TopBackLeft, kAudioChannelLabel_TopBackLeft),
            (.bit_TopBackCenter, kAudioChannelLabel_TopBackCenter),
            (.bit_TopBackRight, kAudioChannelLabel_TopBackRight),
        ]
        return ordered.filter { bitmap.contains($0.0) }.map(\.1)
    }
}
