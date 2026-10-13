import AppKit
import SwiftUI

struct Spectrum11BarView: View {
    @ObservedObject var analyzer: SpectrumAnalyzer

    private let isoCenters: [Double] = [
        31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000, 20000
    ]

    @State private var levels: [Float] = Array(repeating: 0, count: 11)
    @State private var peaks: [Float] = Array(repeating: 0, count: 11)

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let height = max(0, proxy.size.height)
            let barCount = CGFloat(levels.count)
            let totalSpacing = 6 * (barCount - 1) + 16
            let availableWidth = max(0, width - totalSpacing)
            let barWidth = max(6, availableWidth / barCount)
            let usableHeight = max(0, height - 20)

            VStack(spacing: 4) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<levels.count, id: \ .self) { index in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 4)
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
                                .frame(width: barWidth, height: max(6, CGFloat(levels[index]) * usableHeight))

                            Rectangle()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: max(2, barWidth * 0.15), height: 3)
                                .offset(y: -CGFloat(peaks[index]) * usableHeight + 4)
                        }
                    }
                }
                .frame(width: width, height: height, alignment: .center)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.24))
            )
        }
        .frame(minWidth: 160, minHeight: 64)
        .onAppear {
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
            peaks[index] = max(peaks[index] * 0.9, levels[index] * 0.92)
        }
    }

    private func bandLevels(from points: [SpectrumAnalyzer.Point]) -> [Float] {
        let ordered = points.sorted { $0.frequency < $1.frequency }
        return isoCenters.enumerated().map { _, center in
            let low = center / sqrt(2.0)
            let high = center * sqrt(2.0)

            let relevant = ordered.filter {
                $0.frequency >= low && $0.frequency <= high
            }

            guard !relevant.isEmpty else { return 0 }
            let avg = relevant.reduce(Float(0)) { partial, point in
                partial + point.level
            } / Float(relevant.count)

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
