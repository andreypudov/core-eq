import CoreGraphics

/// Where the spectrum trace goes, apart from any view: the line along the
/// levels and the fill under it, in the plot's top-left-origin coordinates.
///
/// A file of its own so the unit tests compile it; the view that draws it is
/// AppKit and is covered by the snapshot tests instead.
struct SpectrumBackdropGeometry: Equatable {
    let axis: ResponseAxis
    let plotHeight: CGFloat

    /// Below this nothing is drawn. Silence would otherwise stroke a flat line
    /// along the floor of the plot, which reads as a stray rule under the
    /// frequency labels.
    static let visibleLevel: Float = 0.02

    /// Level 1 at the top of the plot, level 0 on its floor.
    func point(_ point: SpectrumAnalyzer.Point) -> CGPoint {
        CGPoint(x: axis.x(point.frequency), y: plotHeight * (1 - CGFloat(point.level)))
    }

    /// The line and the fill closed along the floor, or nil when there is
    /// nothing to show.
    func paths(_ points: [SpectrumAnalyzer.Point]) -> (line: CGPath, fill: CGPath)? {
        guard points.count > 1, points.contains(where: { $0.level > Self.visibleLevel }) else {
            return nil
        }
        let line = CGMutablePath()
        line.addLines(between: points.map(point))

        let fill = CGMutablePath()
        fill.addPath(line)
        fill.addLine(to: CGPoint(x: axis.x(points[points.count - 1].frequency), y: plotHeight))
        fill.addLine(to: CGPoint(x: axis.x(points[0].frequency), y: plotHeight))
        fill.closeSubpath()
        return (line, fill)
    }
}
