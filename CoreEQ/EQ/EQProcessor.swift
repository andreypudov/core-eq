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

    private struct FilterState {
        var kind = EQFilter.Kind.bell
        var frequency = 1_000.0
        var q = 1.0
        var isEnabled = true
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
    // by the render thread. The render thread may free a small array here;
    // that is a deliberate simplicity trade-off, bounded and rare.
    private let lock = OSAllocatedUnfairLock()
    private var pendingFilters: [EQFilter]?
    private var pendingPreamp: Double?
    private var pendingBypass: Bool?
    private var pendingSampleRate: Double?

    // Render-thread-only state.
    private var filters = [FilterState](repeating: FilterState(), count: EQProcessor.maxFilters)
    private var filterCount = 0
    private var sampleRate = 44_100.0
    private var bypassed = false
    // Output trim, smoothed like the band gains so dragging the preamp slider
    // is a fade rather than a step.
    private var targetPreampLinear = 1.0
    private var currentPreampLinear = 1.0

    // MARK: - Control (any thread)

    func setFilters(_ newFilters: [EQFilter]) {
        lock.lock()
        pendingFilters = newFilters
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
        let newFilters = pendingFilters
        let newPreamp = pendingPreamp
        let newBypass = pendingBypass
        let newRate = pendingSampleRate
        pendingFilters = nil
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

        if let newFilters {
            filterCount = min(newFilters.count, Self.maxFilters)
            for i in 0..<filterCount {
                let filter = newFilters[i]
                if filters[i].kind != filter.kind
                    || filters[i].frequency != filter.frequency
                    || filters[i].q != filter.q
                    || filters[i].isEnabled != filter.isEnabled {
                    filters[i].kind = filter.kind
                    filters[i].frequency = filter.frequency
                    filters[i].q = filter.q
                    filters[i].isEnabled = filter.isEnabled
                    filters[i].needsCoefficientUpdate = true
                    filters[i].resetState()
                }
                // Switching a gain-bearing filter off ramps it to zero, which is
                // the same smooth path a slider drag takes and lands on identity.
                // High and low pass have no gain to ramp, so they switch at once.
                filters[i].targetGain = filter.isEnabled ? filter.gain : 0
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
                // Coefficients come from the same `Biquad` the response curve is
                // drawn from, so the plot always matches the audio.
                if !filters[i].isEnabled, !filters[i].kind.usesGain {
                    filters[i].filter = .identity
                } else {
                    filters[i].filter = Biquad(
                        kind: filters[i].kind,
                        frequency: filters[i].frequency,
                        gain: filters[i].currentGain,
                        q: filters[i].q,
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
