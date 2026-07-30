import Foundation

/// One RBJ audio-cookbook peaking biquad.
///
/// The single definition of what a CoreEQ band *is*, shared by the two places
/// that need it: `EQProcessor`, which runs these coefficients over the audio,
/// and `FrequencyResponseView`, which draws their magnitude response. Keeping
/// one implementation is what makes the curve on screen a truthful picture of
/// the audio path — with a copy in each, a change to the gain law or the Nyquist
/// guard would leave the graph quietly lying about what you are hearing.
///
/// Coefficients are normalised by `a0`, so `a0` is implicitly 1 and the direct
/// form II transposed difference equation is:
///
///     y = b0·x + z1
///     z1 = b1·x − a1·y + z2
///     z2 = b2·x − a2·y
struct PeakingFilter: Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    /// The identity filter: passes its input through untouched.
    static let identity = PeakingFilter()

    /// Bands below this fraction of the sample rate are rendered; the rest
    /// become identity.
    ///
    /// The 0.47 ceiling keeps the 20 kHz band active at a 44.1 kHz sample rate
    /// (0.47 × 44 100 ≈ 20.7 kHz) while staying safely below Nyquist.
    static let nyquistCeiling = 0.47

    /// Below this the band is inaudible and not worth a biquad.
    static let negligibleGainDB = 0.001

    /// The lowest centre frequency worth filtering at all.
    static let minimumFrequency = 10.0

    /// Whether a band at `frequency` with `gain` does anything at `sampleRate`.
    /// Both call sites need this test on its own, independently of the
    /// coefficients — the processor to skip work, the plot to dim the handle.
    static func isActive(frequency: Double, gain: Double, sampleRate: Double) -> Bool {
        frequency > minimumFrequency
            && frequency < sampleRate * nyquistCeiling
            && abs(gain) > negligibleGainDB
    }

    /// Coefficients for a peaking band, or `identity` when the band is inaudible
    /// or sits too close to Nyquist to be realised.
    init(frequency: Double, gain: Double, q: Double, sampleRate: Double) {
        guard Self.isActive(frequency: frequency, gain: gain, sampleRate: sampleRate) else {
            self = .identity
            return
        }
        // Amplitude is the square root of the linear gain, so the peak reaches
        // exactly `gain` dB at the centre frequency.
        let amp = pow(10.0, gain / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2.0 * max(q, 0.05))
        let cosw0 = cos(w0)
        let a0 = 1.0 + alpha / amp

        b0 = (1.0 + alpha * amp) / a0
        b1 = (-2.0 * cosw0) / a0
        b2 = (1.0 - alpha * amp) / a0
        a1 = (-2.0 * cosw0) / a0
        a2 = (1.0 - alpha / amp) / a0
    }

    private init() {}

    /// Magnitude of H(e^jω) in dB at `frequency`, for drawing the response.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2.0 * Double.pi * frequency / sampleRate
        let cosw = cos(w), sinw = sin(w)
        let cos2w = cos(2 * w), sin2w = sin(2 * w)

        let numeratorReal = b0 + b1 * cosw + b2 * cos2w
        let numeratorImag = -(b1 * sinw + b2 * sin2w)
        let denominatorReal = 1.0 + a1 * cosw + a2 * cos2w
        let denominatorImag = -(a1 * sinw + a2 * sin2w)

        let numerator = numeratorReal * numeratorReal + numeratorImag * numeratorImag
        let denominator = denominatorReal * denominatorReal + denominatorImag * denominatorImag
        guard denominator > 0 else { return 0 }
        return 10.0 * log10(numerator / denominator)
    }
}

extension PeakingFilter {
    /// Convenience for a configured band.
    init(band: EQBand, sampleRate: Double) {
        self.init(frequency: band.frequency, gain: band.gain, q: band.q, sampleRate: sampleRate)
    }
}
