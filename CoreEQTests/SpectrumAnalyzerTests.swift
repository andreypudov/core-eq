import Foundation
import Testing

/// The backdrop behind the response curve. It is decoration in the sense that
/// nothing is heard through it — and not decoration at all in the sense that it
/// claims to show what is playing, so it has to be right about silence, about
/// where a tone sits on the axis, and about stopping when the audio does.
@MainActor
struct SpectrumAnalyzerTests {
    private let sampleRate = 48_000.0

    private func makeAnalyzer(_ buffer: SpectrumAudioBuffer) -> SpectrumAnalyzer {
        let rate = sampleRate
        return SpectrumAnalyzer(buffer: buffer, sampleRate: { rate })
    }

    private func write(_ samples: [Float], to buffer: SpectrumAudioBuffer) {
        let data = samples
        data.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            buffer.write(interleaved: base, frames: samples.count, channels: 1)
        }
    }

    private func sine(_ frequency: Double, frames: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    /// Plays `samples` into the analyzer the way the engine does — a buffer at
    /// a time, analysed between buffers.
    ///
    /// Analysis only recomputes when new audio has arrived; call it twice on
    /// one buffer and the second call decays the display instead. So the audio
    /// and the frames have to advance together, exactly as they do in the app.
    private func play(
        _ samples: [Float], into buffer: SpectrumAudioBuffer, analyser: SpectrumAnalyzer
    ) {
        let chunk = 1_024
        for start in stride(from: 0, to: samples.count, by: chunk) {
            write(Array(samples[start..<min(start + chunk, samples.count)]), to: buffer)
            analyser.analyze()
        }
    }

    // MARK: - The axis it draws on

    /// The points are the x-axis of the backdrop, so they must be ascending and
    /// cover the audible range — a duplicate or an out-of-order point would
    /// fold the display back on itself.
    @Test func thePointsAreAscendingAndCoverTheAudibleRange() {
        let analyzer = makeAnalyzer(SpectrumAudioBuffer(capacity: 8_192))

        #expect(!analyzer.points.isEmpty)
        #expect(
            analyzer.points.map(\.frequency).sorted() == analyzer.points.map(\.frequency),
            "the points are not in ascending frequency order")
        #expect(analyzer.points.first!.frequency.isClose(to: 20, within: 0.001))
        #expect(analyzer.points.last!.frequency.isClose(to: 20_000, within: 0.001))
    }

    @Test func itStartsSilentAndNotRunning() {
        let analyzer = makeAnalyzer(SpectrumAudioBuffer(capacity: 8_192))

        #expect(!analyzer.isRunning)
        #expect(analyzer.points.allSatisfy { $0.level == 0 }, "the backdrop starts at rest")
    }

    @Test func startingAndStoppingTracksState() {
        let analyzer = makeAnalyzer(SpectrumAudioBuffer(capacity: 8_192))

        analyzer.start()
        #expect(analyzer.isRunning)
        analyzer.stop()
        #expect(!analyzer.isRunning)
        #expect(
            analyzer.points.allSatisfy { $0.level == 0 },
            "stopping has to clear the display, not freeze the last frame")
    }

    // MARK: - What it shows

    /// A tone should raise the display where the tone is, and leave the far end
    /// of the spectrum alone. This is the claim the backdrop makes.
    @Test func aToneLiftsItsOwnPartOfTheSpectrum() {
        let buffer = SpectrumAudioBuffer(capacity: 8_192)
        let analyzer = makeAnalyzer(buffer)

        // Twenty buffers of tone: the display attacks quickly but not instantly.
        play(sine(1_000, frames: 1_024 * 20, amplitude: 0.8), into: buffer, analyser: analyzer)

        let near = level(analyzer, closestTo: 1_000)
        let far = level(analyzer, closestTo: 15_000)
        #expect(near > 0.2, "a 1 kHz tone left the display at 1 kHz empty")
        #expect(near > far * 2, "the tone did not stand out from the rest of the spectrum")
    }

    /// Silence has to read as silence rather than as the last thing that
    /// played — a frozen backdrop over a stopped engine is a lie.
    @Test func silenceDecaysTheDisplayToNothing() {
        let buffer = SpectrumAudioBuffer(capacity: 8_192)
        let analyzer = makeAnalyzer(buffer)

        play(sine(1_000, frames: 1_024 * 20, amplitude: 0.8), into: buffer, analyser: analyzer)
        #expect(level(analyzer, closestTo: 1_000) > 0.2)

        play([Float](repeating: 0, count: 1_024 * 60), into: buffer, analyser: analyzer)

        #expect(
            analyzer.points.map(\.level).max() ?? 1 < 0.02,
            "the display kept showing audio that had stopped")
    }

    @Test func levelsStayInsideTheirRange() {
        let buffer = SpectrumAudioBuffer(capacity: 8_192)
        let analyzer = makeAnalyzer(buffer)

        // Far louder than anything the tap will ever carry.
        play(sine(200, frames: 1_024 * 40, amplitude: 4), into: buffer, analyser: analyzer)

        for point in analyzer.points {
            #expect(
                (0...1).contains(point.level),
                "\(point.frequency) Hz is at \(point.level), outside the 0...1 the plot expects")
        }
    }

    private func level(_ analyzer: SpectrumAnalyzer, closestTo frequency: Double) -> Float {
        analyzer.points
            .min { abs($0.frequency - frequency) < abs($1.frequency - frequency) }?
            .level ?? 0
    }
}
