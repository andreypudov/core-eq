import Foundation

/// The equalizer itself: a flat chain of biquads, run over every routed channel.
///
/// Everything about *where* audio comes from and goes to belongs to
/// `BufferRouter`; everything about what happens to the samples in between is
/// here. Kept apart because they fail differently — a routing mistake sends
/// audio to the wrong place, a filter mistake makes it the wrong shape, and
/// telling those apart in one 500 line type was harder than it needed to be.
///
/// The chain has no notion of bands, sliders, or ladders. It receives whatever
/// the user's editing surfaces produced and runs every entry the same way, which
/// is what makes CoreEQ's two editors two views of one equalizer.
///
/// A struct, stored inline by the processor. Every field here is touched on the
/// audio thread, where a class would add a retain and an indirection per block.
struct FilterBank {

    /// Eleven ladder slots plus `BuiltInProfiles.maxFreeFilters`, with room left
    /// for automatically generated processing later. Each filter is one more
    /// pass over the buffer, so this is a real budget.
    static let maxFilters = 32

    /// How long a gain change takes to travel, so a profile switch is a fade
    /// rather than a step.
    private static let smoothingSeconds = 0.05

    /// One filter, as the main thread describes it.
    struct Parameters: Equatable {
        var kind = EQFilter.Kind.bell
        var frequency = 1_000.0
        var gain = 0.0
        var q = 1.0
        var isEnabled = true

        init() {}

        init(_ filter: EQFilter) {
            kind = filter.kind
            frequency = filter.frequency
            gain = filter.gain
            q = filter.q
            isEnabled = filter.isEnabled
        }

        /// Whether a change here invalidates the coefficients and the filter's
        /// delay line. Gain is excluded: it is ramped rather than jumped, so it
        /// updates coefficients without discarding state.
        func changesShape(from other: Parameters) -> Bool {
            kind != other.kind || frequency != other.frequency || q != other.q
                || isEnabled != other.isEnabled
        }
    }

    /// One filter, as the render thread holds it.
    private struct State {
        var parameters = Parameters()
        var targetGain = 0.0
        var currentGain = 0.0
        var needsCoefficientUpdate = true
        var filter = Biquad.identity
    }

    private(set) var sampleRate = 44_100.0

    private var filters = [State](repeating: State(), count: FilterBank.maxFilters)
    private var count = 0

    /// Delay lines for every filter and channel, flat and allocated once:
    /// filter-major, then channel, then the two states. Two per filter per
    /// channel is what transposed direct form II needs.
    private var delays = [Double](
        repeating: 0, count: FilterBank.maxFilters * EQProcessor.maxChannels * 2)

    /// Output trim, smoothed like the band gains so dragging the preamp slider
    /// is a fade rather than a step.
    private var targetPreampLinear = 1.0
    private var currentPreampLinear = 1.0

    // MARK: - Configuration (render thread, from staged values)

    /// Adopts a new rate, returning whether it was one. Coefficients are a
    /// function of `2πf/fs`, so every filter has to be rebuilt and every delay
    /// line dropped — the state describes a response that no longer exists.
    mutating func setSampleRate(_ rate: Double) -> Bool {
        guard rate != sampleRate else { return false }
        sampleRate = rate
        for i in 0..<count {
            filters[i].needsCoefficientUpdate = true
            resetDelays(filter: i)
        }
        return true
    }

    mutating func setFilters(_ staged: [Parameters], count newCount: Int) {
        count = newCount
        for i in 0..<count {
            let parameters = staged[i]
            if parameters.changesShape(from: filters[i].parameters) {
                filters[i].needsCoefficientUpdate = true
                resetDelays(filter: i)
            }
            filters[i].parameters = parameters
            // Switching a gain-bearing filter off ramps it to zero, which is the
            // same smooth path a slider drag takes and lands on identity. High
            // and low pass have no gain to ramp, so they switch at once.
            filters[i].targetGain = parameters.isEnabled ? parameters.gain : 0
        }
    }

    mutating func setPreamp(dB: Double) {
        targetPreampLinear = pow(10.0, dB / 20.0)
    }

    /// Drops every delay line. For discontinuities the filters cannot know
    /// about: a different set of channels, a different input buffer, a pause in
    /// the audio, or coming back from bypass.
    mutating func resetAll() {
        for i in 0..<delays.count { delays[i] = 0 }
    }

    // MARK: - Running (render thread)

    /// Moves gains and the trim one block closer to where they are going, and
    /// rebuilds any coefficients that need it.
    ///
    /// Once per block rather than per channel: every channel shares the same
    /// filter shapes, and rebuilding them per channel would be the same
    /// arithmetic done `channels` times for the same answer.
    mutating func advance(frames: Int) {
        let step = min(1.0, Double(frames) / (sampleRate * Self.smoothingSeconds))

        if currentPreampLinear != targetPreampLinear {
            let next = currentPreampLinear + (targetPreampLinear - currentPreampLinear) * step
            currentPreampLinear =
                abs(next - targetPreampLinear) < 0.0005 ? targetPreampLinear : next
        }
        for i in 0..<count {
            if filters[i].currentGain != filters[i].targetGain {
                var gain =
                    filters[i].currentGain + (filters[i].targetGain - filters[i].currentGain) * step
                if abs(gain - filters[i].targetGain) < 0.02 {
                    gain = filters[i].targetGain
                }
                filters[i].currentGain = gain
                filters[i].needsCoefficientUpdate = true
            }
            if filters[i].needsCoefficientUpdate {
                let parameters = filters[i].parameters
                // Coefficients come from the same `Biquad` the response curve is
                // drawn from, so the plot always matches the audio.
                if !parameters.isEnabled, !parameters.kind.usesGain {
                    filters[i].filter = .identity
                } else {
                    filters[i].filter = Biquad(
                        kind: parameters.kind,
                        frequency: parameters.frequency,
                        gain: filters[i].currentGain,
                        q: parameters.q,
                        sampleRate: sampleRate
                    )
                }
                filters[i].needsCoefficientUpdate = false
            }
        }
    }

    /// Runs the whole chain over one channel, in place.
    mutating func process(
        _ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int, channel: Int
    ) {
        for i in 0..<count {
            let filter = filters[i].filter
            // Identity filters are the common case — every band the user has not
            // touched — so skipping them keeps an untouched chain nearly free.
            if filter == .identity { continue }
            let b0 = filter.b0
            let b1 = filter.b1
            let b2 = filter.b2
            let a1 = filter.a1
            let a2 = filter.a2
            let slot = delayIndex(filter: i, channel: channel)
            var z1 = delays[slot]
            var z2 = delays[slot + 1]

            var index = 0
            for _ in 0..<frames {
                let x = Double(samples[index])
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                samples[index] = Float(y)
                index += stride
            }

            // Flush denormals so idle audio does not burn CPU.
            if abs(z1) < 1e-15 { z1 = 0 }
            if abs(z2) < 1e-15 { z2 = 0 }
            delays[slot] = z1
            delays[slot + 1] = z2
        }
    }

    /// Applies the output trim, in place.
    func applyPreamp(_ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int) {
        guard currentPreampLinear != 1.0 else { return }
        let gain = Float(currentPreampLinear)
        var index = 0
        for _ in 0..<frames {
            samples[index] *= gain
            index += stride
        }
    }

    // MARK: - Delay lines

    /// First of the two delay-line slots for one filter on one channel.
    private func delayIndex(filter: Int, channel: Int) -> Int {
        (filter * EQProcessor.maxChannels + channel) * 2
    }

    /// Clears one filter's delay lines across every channel. Called when a
    /// filter's shape changes, because the state describes the old response.
    private mutating func resetDelays(filter: Int) {
        let base = filter * EQProcessor.maxChannels * 2
        for offset in 0..<(EQProcessor.maxChannels * 2) {
            delays[base + offset] = 0
        }
    }
}
