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
}
