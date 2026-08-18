import SwiftUI



struct SpectrumBackdrop: View {
    @ObservedObject var spectrum: SpectrumAnalyzer
    let axis: ResponseAxis
    let plotHeight: CGFloat

    var body: some View {
        Canvas { context, _ in
            let points = spectrum.points
            // Silence would otherwise stroke a flat line along the floor of the
            // plot, which reads as a stray rule under the frequency labels.
            guard points.count > 1, points.contains(where: { $0.level > 0.02 }) else { return }

            var line = Path()
            for (index, point) in points.enumerated() {
                let position = CGPoint(x: axis.x(point.frequency), y: plotHeight * (1 - CGFloat(point.level)))
                if index == 0 {
                    line.move(to: position)
                } else {
                    line.addLine(to: position)
                }
            }

            var fill = line
            fill.addLine(to: CGPoint(x: axis.x(points[points.count - 1].frequency), y: plotHeight))
            fill.addLine(to: CGPoint(x: axis.x(points[0].frequency), y: plotHeight))
            fill.closeSubpath()

            // Deliberately faint: the analyzer is context for the curve, not a
            // second subject.
            context.fill(fill, with: .color(.primary.opacity(0.05)))
            context.stroke(line, with: .color(.primary.opacity(0.13)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
