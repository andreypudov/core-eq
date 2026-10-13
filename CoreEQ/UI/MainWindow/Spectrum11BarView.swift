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
                            .frame(
                                width: 12,
                                height: max(6, CGFloat(levels[index]) * 56)
                            )

                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 2, height: 3)
                            .offset(y: -CGFloat(peaks[index]) * 56 + 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 200, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.24))
        )
        .onAppear {
            analyzer.start()
            updateLevels()
        }
        .onDisappear {
            analyzer.stop()
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
