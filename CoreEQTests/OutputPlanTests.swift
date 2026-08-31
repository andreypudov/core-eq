import CoreAudio
import Testing

/// Where each tap channel goes.
///
/// This is the decision the engine used to make inline, in a `@MainActor` type
/// full of Core Audio calls, where nothing could reach it. Every multichannel
/// defect found so far has been in this decision rather than in the DSP, so it
/// is worth testing on its own.
struct OutputPlanTests {

    // MARK: - A tap that matches the device

    /// A device-bound tap took the device stream's format, so channel *i* is
    /// channel *i* and nothing needs placing.
    @Test func aDeviceBoundTapMapsChannelsStraightThrough() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(tapChannels: 6, isDeviceBound: true, deviceChannels: 6))

        #expect(layout.tapChannels == 6)
        #expect(layout.destinations == [0, 1, 2, 3, 4, 5])
    }

    @Test func aDeviceBoundStereoTapIsStillJustStereo() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(tapChannels: 2, isDeviceBound: true, deviceChannels: 2))

        #expect(layout.destinations == [0, 1])
    }

    // MARK: - A stereo mixdown that has to be placed

    /// The fallback tap is a two channel mixdown. On a wider device it goes to
    /// the front pair and the rest of the device stays silent.
    @Test func aMixdownGoesToTheFirstPairByDefault() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(tapChannels: 2, isDeviceBound: false, deviceChannels: 8))

        #expect(layout.tapChannels == 2)
        #expect(layout.destinations == [0, 1])
    }

    /// The Core Audio header is explicit that a device's stereo pair need not be
    /// its first two channels, so what the device says wins.
    @Test func aMixdownFollowsTheDevicesOwnStereoPair() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(
                tapChannels: 2, isDeviceBound: false, deviceChannels: 8,
                preferredStereo: StereoPair(left: 4, right: 5)))

        #expect(layout.destinations == [4, 5])
    }

    /// A device claiming a pair it does not have would route audio into nothing,
    /// so the claim is checked against the channels it actually presents.
    @Test func aStereoPairBeyondTheDeviceIsRejected() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(
                tapChannels: 2, isDeviceBound: false, deviceChannels: 2,
                preferredStereo: StereoPair(left: 6, right: 7)))

        #expect(layout.destinations == [0, 1], "an impossible pair was taken at face value")
    }

    @Test func aNegativeStereoPairIsRejected() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(
                tapChannels: 2, isDeviceBound: false, deviceChannels: 4,
                preferredStereo: StereoPair(left: -1, right: 0)))

        #expect(layout.destinations == [0, 1])
    }

    /// A device that declines to report a pair — an HDMI display tested during
    /// this work does exactly that — gets the first two channels.
    @Test func aSilentDeviceGetsTheFirstPair() {
        let description = DeviceDescription(
            tapChannels: 2, isDeviceBound: false, deviceChannels: 6, preferredStereo: nil)

        #expect(OutputPlan.stereo(for: description) == StereoPair(left: 0, right: 1))
    }

    // MARK: - Choosing a stream to bind to

    /// The tap binds to one stream. Binding to a narrower one than the device
    /// offers would leave the rest of its channels silent.
    @Test func theWidestStreamWins() {
        #expect(OutputPlan.widestStream(of: [2, 8, 2]) == 1)
    }

    @Test func tiesGoToTheDevicesOwnOrder() {
        #expect(OutputPlan.widestStream(of: [2, 2, 2]) == 0)
    }

    @Test func aSingleStreamDeviceIsUnambiguous() {
        #expect(OutputPlan.widestStream(of: [2]) == 0)
    }

    /// A device reporting no streams leaves stream 0 as the only thing to try.
    @Test func noStreamsFallsBackToTheFirst() {
        #expect(OutputPlan.widestStream(of: []) == 0)
    }

    // MARK: - Degenerate taps

    /// A tap reporting no channels must produce an empty map rather than a
    /// range that traps.
    @Test func aTapWithNoChannelsMapsNothing() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(tapChannels: 0, isDeviceBound: true, deviceChannels: 2))

        #expect(layout.destinations.isEmpty)
    }
    // MARK: - Finding the tap in the aggregate's input list

    /// An output-only device contributes no input buffers, so the tap is the
    /// only thing in the list and sits first.
    @Test func anOutputOnlyDeviceLeavesTheTapFirst() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(tapChannels: 2, isDeviceBound: true, deviceChannels: 2))

        #expect(layout.tapBufferIndex == 0)
    }

    /// The BlackHole 16ch bug. A duplex device presents an input stream of its
    /// own, and the aggregate lists it *before* the tap. Matching by channel
    /// count picked that stream — same width as the tap, and silent, because the
    /// tap had muted everything — so CoreEQ equalized silence and played it back
    /// while every other process stayed muted.
    @Test func aDuplexDevicePushesTheTapPastItsOwnInput() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(
                tapChannels: 16, isDeviceBound: true, deviceChannels: 16, inputBuffers: 1))

        #expect(layout.tapBufferIndex == 1)
        #expect(layout.destinations == Array(0..<16))
    }

    /// The mixdown path is bound to the same aggregate, so it needs the offset
    /// just as much — and a stereo tap behind a 2-in device is the collision
    /// that hides most easily.
    @Test func aMixdownOnADuplexDeviceIsAlsoOffset() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(
                tapChannels: 2, isDeviceBound: false, deviceChannels: 2, inputBuffers: 1))

        #expect(layout.tapBufferIndex == 1)
        #expect(layout.destinations == [0, 1])
    }

    /// A device reporting several input streams pushes the tap that much
    /// further down.
    @Test func severalInputBuffersPushTheTapFurther() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(
                tapChannels: 8, isDeviceBound: true, deviceChannels: 8, inputBuffers: 3))

        #expect(layout.tapBufferIndex == 3)
    }

    /// `OutputPlan` maps every channel the tap delivers, however many that is.
    /// The 16 channel ceiling belongs to `EQProcessor`, which allocates delay
    /// lines against it — so a 64 channel BlackHole is mapped in full here and
    /// clamped there.
    ///
    /// The two disagreeing is deliberate but worth knowing: the diagnostics
    /// report prints *this* map, so on such a device it names destinations the
    /// render path will not use.
    @Test func aTapWiderThanTheProcessorIsStillMappedInFull() {
        let layout = OutputPlan.layout(
            for: DeviceDescription(tapChannels: 64, isDeviceBound: true, deviceChannels: 64))

        #expect(layout.tapChannels == 64)
        #expect(layout.destinations.count == 64)
        #expect(layout.destinations.last == 63)
    }

    // MARK: - Devices that present several output streams

    /// A tap binds to one stream, so a device presenting eight stereo streams
    /// needs eight taps. Each one's channel 0 belongs at its own offset.
    @Test func everyStreamGetsATapAtItsOwnOffset() {
        let plans = OutputPlan.tapPlans(forStreams: [2, 2, 2, 2])

        #expect(plans.count == 4)
        #expect(plans.map(\.firstOutputChannel) == [0, 2, 4, 6])
        #expect(plans.map(\.channels) == [2, 2, 2, 2])
    }

    /// Streams need not be the same width.
    @Test func unevenStreamsAccumulateCorrectly() {
        let plans = OutputPlan.tapPlans(forStreams: [8, 2, 4])

        #expect(plans.map(\.firstOutputChannel) == [0, 8, 10])
    }

    /// A stream with no channels contributes no tap and no offset.
    @Test func anEmptyStreamIsSkipped() {
        let plans = OutputPlan.tapPlans(forStreams: [2, 0, 2])

        #expect(plans.count == 2)
        #expect(plans.map(\.firstOutputChannel) == [0, 2])
    }

    /// The routed order runs tap by tap, each tap's own channels in order, so
    /// routed channel 3 is the second channel of the second tap — not the
    /// fourth channel of anything.
    @Test func severalTapsAreRoutedTapByTap() {
        let layout = OutputPlan.layout(
            forTaps: OutputPlan.tapPlans(forStreams: [2, 2, 2]), inputBuffers: 0)

        #expect(layout.tapChannels == 6)
        #expect(layout.destinations == [0, 1, 2, 3, 4, 5])
        #expect(layout.sourceBuffers == [0, 0, 1, 1, 2, 2])
        #expect(layout.sourceChannels == [0, 1, 0, 1, 0, 1])
        #expect(layout.primaryTapChannels == 2)
    }

    /// The taps sit after whatever input buffers the device contributes, so a
    /// duplex multi-stream device offsets every one of them.
    @Test func severalTapsSitAfterTheDevicesOwnInputBuffers() {
        let layout = OutputPlan.layout(
            forTaps: OutputPlan.tapPlans(forStreams: [4, 4]), inputBuffers: 2)

        #expect(layout.tapBufferIndex == 2)
        #expect(layout.sourceBuffers == [2, 2, 2, 2, 3, 3, 3, 3])
        #expect(layout.destinations == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    /// A single stream through the multi-tap path must come out identical to the
    /// single-tap path, because that is the case every tested device is in.
    @Test func oneStreamThroughTheTapPathIsTheOrdinaryLayout() {
        let many = OutputPlan.layout(
            forTaps: OutputPlan.tapPlans(forStreams: [16]), inputBuffers: 1)
        let one = OutputPlan.layout(
            for: DeviceDescription(
                tapChannels: 16, isDeviceBound: true, deviceChannels: 16, inputBuffers: 1))

        #expect(many.destinations == one.destinations)
        #expect(many.sourceBuffers == one.sourceBuffers)
        #expect(many.sourceChannels == one.sourceChannels)
        #expect(many.tapBufferIndex == one.tapBufferIndex)
        #expect(many.primaryTapChannels == one.primaryTapChannels)
    }

    // MARK: - Channel roles

    /// A bitmap says which roles are present but not their order; Core Audio
    /// lays them out in bit order. 5.1 as a bitmap therefore puts LFE third.
    @Test func aSurroundBitmapPutsLFEWhereTheOrderSaysItIs() {
        let labels = ChannelRoles.labels(
            fromBitmap: [
                .bit_Left, .bit_Right, .bit_Center, .bit_LFEScreen,
                .bit_LeftSurround, .bit_RightSurround,
            ])

        #expect(labels.count == 6)
        #expect(labels[3] == kAudioChannelLabel_LFEScreen)
    }

    /// A layout with no LFE bit names no LFE channel — rather than defaulting to
    /// the third, which is where most layouts happen to keep one.
    @Test func aBitmapWithoutLFENamesNone() {
        let labels = ChannelRoles.labels(fromBitmap: [.bit_Left, .bit_Right])

        #expect(labels == [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
        #expect(!labels.contains(kAudioChannelLabel_LFEScreen))
    }

    /// An empty bitmap is a device saying nothing, which must not become a
    /// confident claim about channel zero.
    @Test func anEmptyBitmapNamesNothing() {
        #expect(ChannelRoles.labels(fromBitmap: []).isEmpty)
    }

}
