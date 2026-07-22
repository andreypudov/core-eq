import CoreAudio
import Foundation
import os

/// Realtime-safe multi-band peaking equalizer.
///
/// The render path (`render(input:output:)`) runs on the Core Audio IO thread
/// and never blocks: parameter changes from the main thread are staged behind
/// an unfair lock and picked up with `lockIfAvailable()`; if the lock is
/// contended the previous parameters are simply reused for one more cycle.
/// Gain changes are smoothed over ~50 ms so profile switches are glitch-free.
///
/// Filters are RBJ audio-cookbook peaking biquads, processed in transposed
/// direct form II with per-band, per-channel state.
final class EQProcessor {
    static let maxBands = 16
    static let maxChannels = 2

    private static let smoothingSeconds = 0.05

    private struct BandState {
        var frequency = 1_000.0
        var q = 1.0
        var targetGain = 0.0
        var currentGain = 0.0
        var needsCoefficientUpdate = true
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1L = 0.0, z2L = 0.0, z1R = 0.0, z2R = 0.0

        mutating func resetState() {
            z1L = 0; z2L = 0; z1R = 0; z2R = 0
        }
    }

    // Staged parameters, written by the main thread under `lock` and consumed
    // by the render thread. The render thread may free a small array here;
    // that is a deliberate simplicity trade-off, bounded and rare.
    private let lock = OSAllocatedUnfairLock()
    private var pendingBands: [EQBand]?
    private var pendingBypass: Bool?
    private var pendingSampleRate: Double?

    // Render-thread-only state.
    private var bands = [BandState](repeating: BandState(), count: EQProcessor.maxBands)
    private var bandCount = 0
    private var sampleRate = 44_100.0
    private var bypassed = false

    // MARK: - Control (any thread)

    func setBands(_ newBands: [EQBand]) {
        lock.lock()
        pendingBands = newBands
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

        guard !bypassed, bandCount > 0, totalFrames > 0 else { return }

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
            channelBase += channels
        }
    }

    // MARK: - Render-thread helpers

    private func consumePendingParameters() {
        guard lock.lockIfAvailable() else { return }
        let newBands = pendingBands
        let newBypass = pendingBypass
        let newRate = pendingSampleRate
        pendingBands = nil
        pendingBypass = nil
        pendingSampleRate = nil
        lock.unlock()

        if let newRate, newRate != sampleRate {
            sampleRate = newRate
            for i in 0..<bandCount {
                bands[i].needsCoefficientUpdate = true
                bands[i].resetState()
            }
        }

        if let newBands {
            bandCount = min(newBands.count, Self.maxBands)
            for i in 0..<bandCount {
                let band = newBands[i]
                if bands[i].frequency != band.frequency || bands[i].q != band.q {
                    bands[i].frequency = band.frequency
                    bands[i].q = band.q
                    bands[i].needsCoefficientUpdate = true
                    bands[i].resetState()
                }
                bands[i].targetGain = band.gain
            }
        }

        if let newBypass, newBypass != bypassed {
            bypassed = newBypass
            if !bypassed {
                for i in 0..<bandCount { bands[i].resetState() }
            }
        }
    }

    private func advanceSmoothing(frames: Int) {
        let step = min(1.0, Double(frames) / (sampleRate * Self.smoothingSeconds))
        for i in 0..<bandCount {
            if bands[i].currentGain != bands[i].targetGain {
                var gain = bands[i].currentGain + (bands[i].targetGain - bands[i].currentGain) * step
                if abs(gain - bands[i].targetGain) < 0.02 {
                    gain = bands[i].targetGain
                }
                bands[i].currentGain = gain
                bands[i].needsCoefficientUpdate = true
            }
            if bands[i].needsCoefficientUpdate {
                computeCoefficients(&bands[i])
                bands[i].needsCoefficientUpdate = false
            }
        }
    }

    private func computeCoefficients(_ band: inout BandState) {
        // Bands at or above Nyquist, or with negligible gain, become identity.
        // The 0.47 ceiling keeps the 20 kHz band active at a 44.1 kHz sample
        // rate (0.47 × 44 100 ≈ 20.7 kHz) while staying safely below Nyquist.
        guard band.frequency > 10, band.frequency < sampleRate * 0.47, abs(band.currentGain) > 0.001 else {
            band.b0 = 1; band.b1 = 0; band.b2 = 0; band.a1 = 0; band.a2 = 0
            return
        }
        let amp = pow(10.0, band.currentGain / 40.0)
        let w0 = 2.0 * Double.pi * band.frequency / sampleRate
        let alpha = sin(w0) / (2.0 * max(band.q, 0.05))
        let cosw0 = cos(w0)
        let a0 = 1.0 + alpha / amp
        band.b0 = (1.0 + alpha * amp) / a0
        band.b1 = (-2.0 * cosw0) / a0
        band.b2 = (1.0 - alpha * amp) / a0
        band.a1 = (-2.0 * cosw0) / a0
        band.a2 = (1.0 - alpha / amp) / a0
    }

    private func processChannel(_ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int, channel: Int) {
        for i in 0..<bandCount {
            let b0 = bands[i].b0, b1 = bands[i].b1, b2 = bands[i].b2
            let a1 = bands[i].a1, a2 = bands[i].a2
            var z1 = channel == 0 ? bands[i].z1L : bands[i].z1R
            var z2 = channel == 0 ? bands[i].z2L : bands[i].z2R

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
                bands[i].z1L = z1; bands[i].z2L = z2
            } else {
                bands[i].z1R = z1; bands[i].z2R = z2
            }
        }
    }
}
