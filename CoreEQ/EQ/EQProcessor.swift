import CoreAudio
import Foundation
import os

/// Realtime-safe equalizer: one flat chain of biquads.
///
/// The processor has no notion of bands, sliders, or lists — it receives the
/// whole chain as an array and runs every entry the same way. That is what
/// makes CoreEQ's two editing surfaces two views of one equalizer rather than
/// two equalizers.
///
/// The render path (`render(input:output:)`) runs on the Core Audio IO thread
/// and never blocks: parameter changes from the main thread are staged behind
/// an unfair lock and picked up with `lockIfAvailable()`; if the lock is
/// contended the previous parameters are simply reused for one more cycle.
/// Gain changes are smoothed over ~50 ms so profile switches are glitch-free.
///
/// Filters are RBJ audio-cookbook biquads, processed in transposed direct form
/// II with per-filter, per-channel state.
final class EQProcessor {
    /// Eleven ladder slots plus `BuiltInProfiles.maxFreeFilters`, with room left
    /// for automatically generated processing later. Each filter is one more
    /// pass over the buffer in `processChannel`, so this is a real budget.
    static let maxFilters = 32
    static let maxChannels = 2

    private static let smoothingSeconds = 0.05

    /// Mono copy of the played-back output, tapped for the spectrum analyzer.
    /// 8192 samples is well beyond the analyzer's 4096-sample window, so the
    /// consumer can snapshot without the producer overtaking the read region.
    let spectrumBuffer = SpectrumAudioBuffer(capacity: 8_192)

    /// What the render thread needs to know about one filter: no identifier, no
    /// colour, no ladder slot. Plain data, so staging a chain is a fixed number
    /// of scalar copies into storage that already exists.
    private struct FilterParameters: Equatable {
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
        func changesShape(from other: FilterParameters) -> Bool {
            kind != other.kind
                || frequency != other.frequency
                || q != other.q
                || isEnabled != other.isEnabled
        }
    }

    private struct FilterState {
        var parameters = FilterParameters()
        var targetGain = 0.0
        var currentGain = 0.0
        var needsCoefficientUpdate = true
        var filter = Biquad.identity
        var z1L = 0.0, z2L = 0.0, z1R = 0.0, z2R = 0.0

        mutating func resetState() {
            z1L = 0; z2L = 0; z1R = 0; z2R = 0
        }
    }

    // Staged parameters, written by the main thread under `lock` and consumed
    // by the render thread.
    //
    // The staging chain is allocated once, at its maximum length, and written
    // in place. Handing over a fresh `[EQFilter]` instead would make the render
    // thread the last owner of that array — and therefore the thread that frees
    // it, inside the IO callback, on every parameter change. A slider drag
    // sends one array per frame, so that is a `free()` on the audio thread sixty
    // times a second: unbounded in principle, and exactly the kind of thing that
    // shows up as a dropout under memory pressure rather than in testing.
    private let lock = OSAllocatedUnfairLock()
    private var pendingFilters = [FilterParameters](repeating: FilterParameters(), count: EQProcessor.maxFilters)
    /// Number of staged filters, or nil when no chain is waiting to be picked up.
    private var pendingFilterCount: Int?
    private var pendingPreamp: Double?
    private var pendingBypass: Bool?
    private var pendingSampleRate: Double?

    // Render-thread-only state.
    private var filters = [FilterState](repeating: FilterState(), count: EQProcessor.maxFilters)
    private var filterCount = 0
    /// Where a staged chain is copied to while the lock is held, so the lock is
    /// released before the longer work of comparing it against what is running.
    /// Holding it across that would put the main thread in a position to block
    /// on the audio thread, which is the inversion the staging exists to avoid.
    private var stagedFilters = [FilterParameters](repeating: FilterParameters(), count: EQProcessor.maxFilters)
    private var sampleRate = 44_100.0
    private var bypassed = false
    // Output trim, smoothed like the band gains so dragging the preamp slider
    // is a fade rather than a step.
    private var targetPreampLinear = 1.0
    private var currentPreampLinear = 1.0

    // MARK: - Control (any thread)

    /// Stages a chain for the render thread. Anything past `maxFilters` is
    /// dropped here rather than in the callback, so the render side never has to
    /// reason about a chain longer than its storage.
    func setFilters(_ newFilters: [EQFilter]) {
        let count = min(newFilters.count, Self.maxFilters)
        lock.lock()
        for i in 0..<count {
            pendingFilters[i] = FilterParameters(newFilters[i])
        }
        pendingFilterCount = count
        lock.unlock()
    }

    func setPreamp(_ dB: Double) {
        lock.lock()
        pendingPreamp = dB
        lock.unlock()
    }

    func setBypassed(_ value: Bool) {
        lock.lock()
        pendingBypass = value
        lock.unlock()
    }

    func setSampleRate(_ rate: Double) {
        guard rate > 0 else { return }
        lock.lock()
        pendingSampleRate = rate
        lock.unlock()
    }

    // MARK: - Render (Core Audio IO thread)

    /// Copies tapped system audio from `input` to `output`, applying the EQ
    /// in place unless bypassed. Assumes Float32 samples, the native format
    /// for process taps and aggregate device IO.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outABL = UnsafeMutableAudioBufferListPointer(output)

        consumePendingParameters()

        var totalFrames = 0
        for i in 0..<outABL.count {
            let outBuffer = outABL[i]
            guard let outData = outBuffer.mData else { continue }
            let outBytes = Int(outBuffer.mDataByteSize)
            if i < inABL.count, let inData = inABL[i].mData {
                let copied = min(outBytes, Int(inABL[i].mDataByteSize))
                memcpy(outData, inData, copied)
                if copied < outBytes {
                    memset(outData.advanced(by: copied), 0, outBytes - copied)
                }
            } else {
                memset(outData, 0, outBytes)
            }
            if totalFrames == 0, outBuffer.mNumberChannels > 0 {
                totalFrames = outBytes / (MemoryLayout<Float>.size * Int(outBuffer.mNumberChannels))
            }
        }

        if !bypassed, totalFrames > 0 {
            advanceSmoothing(frames: totalFrames)

            var channelBase = 0
            for i in 0..<outABL.count where channelBase < Self.maxChannels {
                let buffer = outABL[i]
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                for ch in 0..<channels where channelBase + ch < Self.maxChannels {
                    processChannel(data + ch, stride: channels, frames: frames, channel: channelBase + ch)
                }
                applyPreamp(data, count: frames * channels)
                channelBase += channels
            }
        }

        feedSpectrum(outABL)
    }

    /// Hands a mono copy of the final output — equalized when enabled, the
    /// untouched passthrough when bypassed — to the spectrum buffer, so the
    /// analyzer always shows what is actually reaching the speakers. Runs off
    /// the first output buffer, which covers the common interleaved case.
    private func feedSpectrum(_ outABL: UnsafeMutableAudioBufferListPointer) {
        guard let first = outABL.first,
              let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = Int(first.mNumberChannels)
        guard channels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        spectrumBuffer.write(interleaved: data, frames: frames, channels: channels)
    }

    // MARK: - Render-thread helpers

    private func consumePendingParameters() {
        guard lock.lockIfAvailable() else { return }
        // Copied out under the lock into fixed storage the render thread already
        // owns, so nothing is allocated, retained, or released here.
        let newFilterCount = pendingFilterCount
        if let newFilterCount {
            for i in 0..<newFilterCount {
                stagedFilters[i] = pendingFilters[i]
            }
        }
        let newPreamp = pendingPreamp
        let newBypass = pendingBypass
        let newRate = pendingSampleRate
        pendingFilterCount = nil
        pendingPreamp = nil
        pendingBypass = nil
        pendingSampleRate = nil
        lock.unlock()

        if let newRate, newRate != sampleRate {
            sampleRate = newRate
            for i in 0..<filterCount {
                filters[i].needsCoefficientUpdate = true
                filters[i].resetState()
            }
        }

        if let newFilterCount {
            filterCount = newFilterCount
            for i in 0..<filterCount {
                let staged = stagedFilters[i]
                if staged.changesShape(from: filters[i].parameters) {
                    filters[i].needsCoefficientUpdate = true
                    filters[i].resetState()
                }
                filters[i].parameters = staged
                // Switching a gain-bearing filter off ramps it to zero, which is
                // the same smooth path a slider drag takes and lands on identity.
                // High and low pass have no gain to ramp, so they switch at once.
                filters[i].targetGain = staged.isEnabled ? staged.gain : 0
            }
        }

        if let newPreamp {
            targetPreampLinear = pow(10.0, newPreamp / 20.0)
        }

        if let newBypass, newBypass != bypassed {
            bypassed = newBypass
            if !bypassed {
                for i in 0..<filterCount { filters[i].resetState() }
            }
        }
    }

    /// Output trim, applied after every filter — this is the point of the chain
    /// where headroom given away by boosting is taken back.
    private func applyPreamp(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard currentPreampLinear != 1.0 else { return }
        let gain = Float(currentPreampLinear)
        for i in 0..<count {
            samples[i] *= gain
        }
    }

    private func advanceSmoothing(frames: Int) {
        let step = min(1.0, Double(frames) / (sampleRate * Self.smoothingSeconds))

        if currentPreampLinear != targetPreampLinear {
            let next = currentPreampLinear + (targetPreampLinear - currentPreampLinear) * step
            currentPreampLinear = abs(next - targetPreampLinear) < 0.0005 ? targetPreampLinear : next
        }
        for i in 0..<filterCount {
            if filters[i].currentGain != filters[i].targetGain {
                var gain = filters[i].currentGain + (filters[i].targetGain - filters[i].currentGain) * step
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

    private func processChannel(_ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int, channel: Int) {
        for i in 0..<filterCount {
            let filter = filters[i].filter
            // Identity filters are the common case — every band the user has not
            // touched — so skipping them keeps an untouched chain nearly free.
            if filter == .identity { continue }
            let b0 = filter.b0, b1 = filter.b1, b2 = filter.b2
            let a1 = filter.a1, a2 = filter.a2
            var z1 = channel == 0 ? filters[i].z1L : filters[i].z1R
            var z2 = channel == 0 ? filters[i].z2L : filters[i].z2R

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
            if channel == 0 {
                filters[i].z1L = z1; filters[i].z2L = z2
            } else {
                filters[i].z1R = z1; filters[i].z2R = z2
            }
        }
    }
}
