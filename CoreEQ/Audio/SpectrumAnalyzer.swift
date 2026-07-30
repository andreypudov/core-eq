import Accelerate
import Combine
import Foundation
import os

/// Real-time spectrum analyzer that drives the backdrop of the response plot.
///
/// On a display-rate timer it snapshots the latest window of played-back audio,
/// runs a Hann-windowed real FFT (vDSP), and maps the result onto a fixed set
/// of log-spaced frequencies. Levels are normalised to 0...1 and temporally
/// smoothed (fast attack, slow release) so the display moves like a
/// professional analyzer rather than flickering. When no new audio has arrived
/// (engine stopped or silent) the levels decay to zero.
@MainActor
final class SpectrumAnalyzer: ObservableObject {
    struct Point: Equatable {
        let frequency: Double
        var level: Float
    }

    /// Log-spaced points, ascending in frequency; `level` is 0...1.
    @Published private(set) var points: [Point]
    @Published private(set) var isRunning = false

    // Analysis parameters.
    private static let fftSize = 4_096
    private static let displayPointCount = 220
    private static let minFrequency = 20.0
    private static let maxFrequency = 20_000.0

    // Level mapping. The normalisation offset only shifts the whole backdrop
    // up or down uniformly, so these three are safe to tune to taste.
    private static let floorDB: Float = -80
    private static let ceilDB: Float = 0
    private let normalizationDB: Float

    // Smoothing coefficients per frame (~60 Hz): rise quickly, fall gently.
    private static let attack: Float = 0.55
    private static let release: Float = 0.16

    private let buffer: SpectrumAudioBuffer
    private var sampleRateProvider: () -> Double
    private let logger = Logger(subsystem: "com.andreypudov.coreeq", category: "SpectrumAnalyzer")

    private let displayFrequencies: [Double]
    private var smoothed: [Float]

    private var timer: Timer?
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?

    // Scratch buffers, reused every frame to avoid render-time allocation.
    private var window: [Float]
    private var windowed: [Float]
    private var hann: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]
    private var lastTotal: UInt64 = 0

    init(buffer: SpectrumAudioBuffer, sampleRate: @escaping () -> Double) {
        self.buffer = buffer
        self.sampleRateProvider = sampleRate

        let size = Self.fftSize
        window = [Float](repeating: 0, count: size)
        windowed = [Float](repeating: 0, count: size)
        hann = [Float](repeating: 0, count: size)
        realp = [Float](repeating: 0, count: size / 2)
        imagp = [Float](repeating: 0, count: size / 2)
        magnitudes = [Float](repeating: 0, count: size / 2)

        vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        log2n = vDSP_Length(log2(Double(size)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        // Roughly aligns a full-scale tone with the top of the display range;
        // the exact value only slides the backdrop vertically.
        normalizationDB = 20 * log10(Float(size)) - 9

        let logMin = log10(Self.minFrequency)
        let logMax = log10(Self.maxFrequency)
        displayFrequencies = (0..<Self.displayPointCount).map { index in
            let fraction = Double(index) / Double(Self.displayPointCount - 1)
            return pow(10, logMin + (logMax - logMin) * fraction)
        }
        smoothed = [Float](repeating: 0, count: Self.displayPointCount)
        points = displayFrequencies.map { Point(frequency: $0, level: 0) }

        if fftSetup == nil {
            logger.error("Failed to create FFT setup; spectrum analyzer disabled.")
        }
    }

    deinit {
        timer?.invalidate()
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    /// Supplies the current device sample rate, needed to map FFT bins to
    /// frequencies. Set by the owner once `self` is fully initialized.
    func setSampleRateProvider(_ provider: @escaping () -> Double) {
        sampleRateProvider = provider
    }

    // MARK: - Lifecycle

    /// Begins analysis. Called when the main window becomes visible; safe to
    /// call repeatedly.
    func start() {
        guard !isRunning, fftSetup != nil else { return }
        isRunning = true
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.analyze() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops analysis and clears the display. Called when the window is hidden.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        lastTotal = 0
        for i in smoothed.indices { smoothed[i] = 0 }
        for i in points.indices { points[i].level = 0 }
    }

    // MARK: - Analysis

    private func analyze() {
        guard let fftSetup else { return }

        let total = buffer.snapshot(into: &window)
        let hasNewAudio = total != lastTotal
        lastTotal = total
        let sampleRate = sampleRateProvider()

        if hasNewAudio, sampleRate > 0 {
            computeMagnitudes(fftSetup: fftSetup)
            updateLevels(sampleRate: sampleRate)
        } else {
            decayLevels()
        }

        for i in points.indices { points[i].level = smoothed[i] }
    }

    /// Fills `magnitudes` with the power spectrum of the current window.
    private func computeMagnitudes(fftSetup: FFTSetup) {
        vDSP_vmul(window, 1, hann, 1, &windowed, 1, vDSP_Length(Self.fftSize))

        realp.withUnsafeMutableBufferPointer { realBuffer in
            imagp.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
            }
        }
    }

    /// Samples `magnitudes` at each display frequency and folds the result into
    /// the smoothed levels with attack/release.
    private func updateLevels(sampleRate: Double) {
        let binCount = Self.fftSize / 2
        let binsPerHz = Double(Self.fftSize) / sampleRate
        let span = Self.ceilDB - Self.floorDB

        for i in displayFrequencies.indices {
            let binPosition = displayFrequencies[i] * binsPerHz
            let lowBin = Int(binPosition)
            var level: Float = 0
            if lowBin >= 0, lowBin < binCount {
                let fraction = Float(binPosition - Double(lowBin))
                let low = magnitudes[lowBin]
                let high = lowBin + 1 < binCount ? magnitudes[lowBin + 1] : low
                let power = low + (high - low) * fraction
                let db = 10 * log10(power + 1e-20) - normalizationDB
                level = min(max((db - Self.floorDB) / span, 0), 1)
            }
            smooth(i, toward: level)
        }
    }

    private func decayLevels() {
        for i in smoothed.indices { smooth(i, toward: 0) }
    }

    private func smooth(_ index: Int, toward target: Float) {
        let coefficient = target > smoothed[index] ? Self.attack : Self.release
        smoothed[index] += (target - smoothed[index]) * coefficient
    }
}
