import CoreGraphics
import Testing

/// The spectrum trace behind the response curve, as geometry.
///
/// The view draws exactly these paths and nothing else, so whether the trace
/// is in the right place, closes along the floor, and disappears in silence is
/// all decided here.
struct SpectrumBackdropGeometryTests {
    private let geometry = SpectrumBackdropGeometry(
        axis: ResponseAxis(anchors: BuiltInProfiles.frequencies, gutter: 40, width: 880),
        plotHeight: 300)

    private func points(_ levels: [Float]) -> [SpectrumAnalyzer.Point] {
        let frequencies = [20.0, 200, 2_000, 20_000]
        return zip(frequencies, levels).map { SpectrumAnalyzer.Point(frequency: $0, level: $1) }
    }

    /// The path's vertices in order, and whether it was closed.
    private func vertices(_ path: CGPath) -> (points: [CGPoint], closed: Bool) {
        var points: [CGPoint] = []
        var closed = false
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
            case .closeSubpath: closed = true
            default: Issue.record("the trace has a curve segment; it is drawn with lines only")
            }
        }
        return (points, closed)
    }

    // MARK: - Silence

    /// Silence would otherwise stroke a flat line along the floor of the plot,
    /// a stray rule under the frequency labels.
    @Test func silenceDrawsNothing() {
        #expect(geometry.paths(points([0, 0, 0, 0])) == nil)
    }

    /// Below the threshold is silence as far as the screen is concerned — the
    /// slow release would otherwise leave a hairline on the floor for seconds.
    @Test func levelsBelowTheThresholdDrawNothing() {
        let quiet = SpectrumBackdropGeometry.visibleLevel * 0.9
        #expect(geometry.paths(points([quiet, quiet, quiet, quiet])) == nil)
    }

    /// One audible point is enough: the trace is drawn whole, not only where
    /// it is loud.
    @Test func oneAudiblePointDrawsTheWholeTrace() throws {
        let paths = try #require(geometry.paths(points([0, 0.5, 0, 0])))
        #expect(vertices(paths.line).points.count == 4)
    }

    @Test func aSinglePointDrawsNothing() {
        #expect(geometry.paths([SpectrumAnalyzer.Point(frequency: 1_000, level: 1)]) == nil)
    }

    // MARK: - Placement

    /// Full scale at the top of the plot, nothing on its floor, and each
    /// frequency over the same x the curve and the grid use.
    @Test func levelsMapToHeightAndFrequenciesToTheAxis() {
        let top = geometry.point(SpectrumAnalyzer.Point(frequency: 1_000, level: 1))
        let floor = geometry.point(SpectrumAnalyzer.Point(frequency: 1_000, level: 0))
        let middle = geometry.point(SpectrumAnalyzer.Point(frequency: 1_000, level: 0.5))

        #expect(top.y.isClose(to: 0, within: 0.001))
        #expect(floor.y.isClose(to: 300, within: 0.001))
        #expect(middle.y.isClose(to: 150, within: 0.001))
        #expect(top.x.isClose(to: geometry.axis.x(1_000), within: 0.001))
    }

    /// The line passes through every point, left to right, and is left open.
    @Test func theLineFollowsEveryPointInOrder() throws {
        let input = points([0.2, 0.8, 0.5, 0.1])
        let line = vertices(try #require(geometry.paths(input)).line)

        #expect(!line.closed)
        #expect(line.points.count == input.count)
        for (vertex, point) in zip(line.points, input) {
            let expected = geometry.point(point)
            #expect(vertex.x.isClose(to: expected.x, within: 0.001))
            #expect(vertex.y.isClose(to: expected.y, within: 0.001))
        }
    }

    /// The fill is the line, then down to the floor at the last point, back
    /// along the floor to the first, and closed — so it never leaks past the
    /// ends of the trace.
    @Test func theFillClosesAlongTheFloorUnderTheTrace() throws {
        let input = points([0.2, 0.8, 0.5, 0.1])
        let fill = vertices(try #require(geometry.paths(input)).fill)

        #expect(fill.closed)
        #expect(fill.points.count == input.count + 2)
        let lastCorner = fill.points[input.count]
        let firstCorner = fill.points[input.count + 1]
        #expect(lastCorner.x.isClose(to: geometry.axis.x(20_000), within: 0.001))
        #expect(lastCorner.y.isClose(to: 300, within: 0.001))
        #expect(firstCorner.x.isClose(to: geometry.axis.x(20), within: 0.001))
        #expect(firstCorner.y.isClose(to: 300, within: 0.001))
    }
}
