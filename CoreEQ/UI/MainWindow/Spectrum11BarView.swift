import AppKit
import SwiftUI

/// PiP bar view — now 31-band (1/3-octave) display.
///
/// This replaces the previous 11-band visual with 31 bands spanning the
/// audible range. The bands are log-spaced and each covers a 1/3-octave band
/// around its centre frequency.
struct Spectrum11BarView: View {
    @ObservedObject var analyzer: SpectrumAnalyzer

    // Use 31 bands across the audible range. We compute log-spaced centre
    // frequencies from 20 Hz to 20 kHz and treat each as a 1/3-octave band.
    private static let bandCount = 31
    private let isoCenters: [Double]

    @State private var levels: [Float]
    @State private var peaks: [Float]

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        // precompute the 31 log-spaced centre frequencies between 20 Hz and 20 kHz
        let logMin = log10(20.0)
        let logMax = log10(20_000.0)
        self.isoCenters = (0..<Self.bandCount).map { index in
            let fraction = Double(index) / Double(Self.bandCount - 1)
            return pow(10, logMin + (logMax - logMin) * fraction)
        }
        _levels = State(initialValue: Array(repeating: 0, count: Self.bandCount))
        _peaks  = State(initialValue: Array(repeating: 0, count: Self.bandCount))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let height = max(0, proxy.size.height)
            let barCount = CGFloat(levels.count)
            let spacing: CGFloat = 4
            let sidePadding: CGFloat = 8
            let totalSpacing = spacing * (barCount - 1) + sidePadding * 2
            let availableWidth = max(0, width - totalSpacing)
            let barWidth = max(2, availableWidth / barCount)
            let usableHeight = max(0, height - 16)

            VStack(spacing: 4) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<levels.count, id: \ .self) { index in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            colorForLevel(levels[index]),
                                            colorForLevel(min(levels[index] + 0.25, 1))
                                        ]),
                                        startPoint: .bottom,
                                        endPoint: .top
                                    )
                                )
                                .frame(width: barWidth, height: max(4, CGFloat(levels[index]) * usableHeight))

                            // peak indicator
                            Rectangle()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: max(1, barWidth * 0.12), height: 2)
                                .offset(y: -CGFloat(peaks[index]) * usableHeight + 4)
                        }
                    }
                }
                .frame(width: width, height: height, alignment: .center)
                .padding(.horizontal, sidePadding)
                .padding(.vertical, 6)
            }
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.22))
            )
        }
        .frame(minWidth: 200, minHeight: 80)
        .onAppear {
            // Request analyzer running; it's reference-counted so this is safe.
            analyzer.start()
            updateLevels()
        }
        .onReceive(analyzer.$points) { _ in
            updateLevels()
        }
    }

    private func updateLevels() {
        let mapped = bandLevels(from: analyzer.points)
        for index in 0..<mapped.count {
            let target = mapped[index]
            levels[index] = max(0, min(1, target))
            peaks[index] = max(peaks[index] * 0.92, levels[index])
        }
    }

    private func bandLevels(from points: [SpectrumAnalyzer.Point]) -> [Float] {
        let ordered = points.sorted { $0.frequency < $1.frequency }

        // A 1/3-octave band uses +/- 1/6 octave around the centre frequency.
        // ratio = 2^(1/6)
        let ratio = pow(2.0, 1.0 / 6.0)

        return isoCenters.map { center in
            let low = center / ratio
            let high = center * ratio
            let relevant = ordered.filter { $0.frequency >= low && $0.frequency <= high }
            guard !relevant.isEmpty else { return 0 }
            let avg = relevant.reduce(Float(0)) { $0 + $1.level } / Float(relevant.count)
            return min(max(avg, 0), 1)
        }
    }

    private func colorForLevel(_ value: Float) -> Color {
        let clamped = min(max(value, 0), 1)
        if clamped < 0.5 {
            return Color(nsColor: .systemGreen)
        } else if clamped < 0.8 {
            return Color(nsColor: .systemYellow)
        } else {
            return Color(nsColor: .systemRed)
        }
    }
}
