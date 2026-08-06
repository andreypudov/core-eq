import Foundation

/// One RBJ audio-cookbook biquad, in whichever form `EQFilter.Kind` asks for.
///
/// The single definition of what a CoreEQ filter *is*, shared by the two places
/// that need it: `EQProcessor`, which runs these coefficients over the audio,
/// and `FrequencyResponseView`, which draws their magnitude response. Keeping
/// one implementation is what makes the curve on screen a truthful picture of
/// the audio path — with a copy in each, a change to the gain law or the Nyquist
/// guard would leave the graph quietly lying about what you are hearing.
///
/// Every filter kind added here is a new opportunity to break that, so a kind is
/// only worth adding when it earns its place in a listening application.
///
/// Coefficients are normalised by `a0`, so `a0` is implicitly 1 and the direct
/// form II transposed difference equation is:
///
///     y = b0·x + z1
///     z1 = b1·x − a1·y + z2
///     z2 = b2·x − a2·y
struct Biquad: Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    /// The identity filter: passes its input through untouched.
    static let identity = Biquad()

    /// Filters below this fraction of the sample rate are rendered; the rest
    /// become identity.
    ///
    /// The 0.47 ceiling keeps the 20 kHz band active at a 44.1 kHz sample rate
    /// (0.47 × 44 100 ≈ 20.7 kHz) while staying safely below Nyquist.
    static let nyquistCeiling = 0.47

    /// Below this a gain-bearing filter is inaudible and not worth a biquad.
    static let negligibleGainDB = 0.001

    /// The lowest centre frequency worth filtering at all.
    static let minimumFrequency = 10.0

    /// Whether a filter of `kind` does anything at `sampleRate`.
    ///
    /// Both call sites need this test on its own, independently of the
    /// coefficients — the processor to skip work, the plot to dim the handle.
    /// High and low pass have no gain parameter, so for them only the frequency
    /// matters: a 0 dB high pass is still very much doing something.
    static func isActive(kind: EQFilter.Kind, frequency: Double, gain: Double, sampleRate: Double) -> Bool {
        guard frequency > minimumFrequency, frequency < sampleRate * nyquistCeiling else { return false }
        return kind.usesGain ? abs(gain) > negligibleGainDB : true
    }

    /// Coefficients for a filter, or `identity` when it is inaudible or sits too
    /// close to Nyquist to be realised.
    init(kind: EQFilter.Kind, frequency: Double, gain: Double, q: Double, sampleRate: Double) {
        guard Self.isActive(kind: kind, frequency: frequency, gain: gain, sampleRate: sampleRate) else {
            self = .identity
            return
        }

        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2.0 * max(q, 0.05))

        let a0: Double
        switch kind {
        case .bell:
            // Amplitude is the square root of the linear gain, so the peak
            // reaches exactly `gain` dB at the centre frequency.
            let amp = pow(10.0, gain / 40.0)
            a0 = 1.0 + alpha / amp
            b0 = (1.0 + alpha * amp) / a0
            b1 = (-2.0 * cosw0) / a0
            b2 = (1.0 - alpha * amp) / a0
            a1 = (-2.0 * cosw0) / a0
            a2 = (1.0 - alpha / amp) / a0

        case .lowShelf:
            let amp = pow(10.0, gain / 40.0)
            let sqrtAmpAlpha = 2.0 * sqrt(amp) * alpha
            a0 = (amp + 1.0) + (amp - 1.0) * cosw0 + sqrtAmpAlpha
            b0 = amp * ((amp + 1.0) - (amp - 1.0) * cosw0 + sqrtAmpAlpha) / a0
            b1 = 2.0 * amp * ((amp - 1.0) - (amp + 1.0) * cosw0) / a0
            b2 = amp * ((amp + 1.0) - (amp - 1.0) * cosw0 - sqrtAmpAlpha) / a0
            a1 = -2.0 * ((amp - 1.0) + (amp + 1.0) * cosw0) / a0
            a2 = ((amp + 1.0) + (amp - 1.0) * cosw0 - sqrtAmpAlpha) / a0

        case .highShelf:
            let amp = pow(10.0, gain / 40.0)
            let sqrtAmpAlpha = 2.0 * sqrt(amp) * alpha
            a0 = (amp + 1.0) - (amp - 1.0) * cosw0 + sqrtAmpAlpha
            b0 = amp * ((amp + 1.0) + (amp - 1.0) * cosw0 + sqrtAmpAlpha) / a0
            b1 = -2.0 * amp * ((amp - 1.0) + (amp + 1.0) * cosw0) / a0
            b2 = amp * ((amp + 1.0) + (amp - 1.0) * cosw0 - sqrtAmpAlpha) / a0
            a1 = 2.0 * ((amp - 1.0) - (amp + 1.0) * cosw0) / a0
            a2 = ((amp + 1.0) - (amp - 1.0) * cosw0 - sqrtAmpAlpha) / a0

        case .highPass:
            a0 = 1.0 + alpha
            b0 = ((1.0 + cosw0) / 2.0) / a0
            b1 = (-(1.0 + cosw0)) / a0
            b2 = ((1.0 + cosw0) / 2.0) / a0
            a1 = (-2.0 * cosw0) / a0
            a2 = (1.0 - alpha) / a0

        case .lowPass:
            a0 = 1.0 + alpha
            b0 = ((1.0 - cosw0) / 2.0) / a0
            b1 = (1.0 - cosw0) / a0
            b2 = ((1.0 - cosw0) / 2.0) / a0
            a1 = (-2.0 * cosw0) / a0
            a2 = (1.0 - alpha) / a0
        }
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
        guard denominator > 0, numerator > 0 else { return 0 }
        return 10.0 * log10(numerator / denominator)
    }
}

extension Biquad {
    /// Convenience for a configured filter. A disabled filter is identity, so
    /// switching one off in the list removes it from the curve and the audio in
    /// the same step.
    init(filter: EQFilter, sampleRate: Double) {
        guard filter.isEnabled else {
            self = .identity
            return
        }
        self.init(
            kind: filter.kind,
            frequency: filter.frequency,
            gain: filter.gain,
            q: filter.q,
            sampleRate: sampleRate
        )
    }
}
