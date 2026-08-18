import CoreGraphics
import XCTest

/// Where a frequency sits on the plot.
///
/// The graph, the spectrum behind it, the grid, the handles and the hit testing
/// all ask this one type, so an error here would not look like a bug in any of
/// them — everything would simply be in the wrong place together, consistently.
/// It had no tests until it was given a file of its own.
final class ResponseAxisTests: XCTestCase {
    private let anchors = BuiltInProfiles.frequencies

    private func axis(width: CGFloat = 880, gutter: CGFloat = 0) -> ResponseAxis {
        ResponseAxis(anchors: anchors, gutter: gutter, width: width)
    }

    /// The axis exists to line the graph up with the slider strip: band `i` sits
    /// at the centre of the `i`th of eleven equal columns, which is where its
    /// slider is.
    func testEachBandSitsOnItsSlidersCentreline() {
        let axis = axis()
        let slot = 1.0 / Double(anchors.count)

        for (index, frequency) in anchors.enumerated() {
            let expected = (Double(index) + 0.5) * slot
            XCTAssertEqual(
                axis.fraction(of: frequency), expected, accuracy: 0.0001,
                "\(frequency) Hz is not above its own slider"
            )
        }
    }

    func testTheMappingIsMonotonic() {
        let axis = axis()
        var previous = -Double.infinity
        for frequency in stride(from: 20.0, through: 20_000.0, by: 25.0) {
            let fraction = axis.fraction(of: frequency)
            XCTAssertGreaterThan(
                fraction, previous, "the axis folded back on itself at \(frequency) Hz")
            previous = fraction
        }
    }

    /// Between two rungs it interpolates logarithmically, so the geometric mean
    /// of a pair lands exactly halfway between them.
    func testFrequenciesBetweenRungsInterpolateLogarithmically() {
        let axis = axis()
        for index in 0..<(anchors.count - 1) {
            let low = anchors[index]
            let high = anchors[index + 1]
            let middle = (low * high).squareRoot()
            let expected = (axis.fraction(of: low) + axis.fraction(of: high)) / 2
            XCTAssertEqual(axis.fraction(of: middle), expected, accuracy: 0.0001)
        }
    }

    /// Sweeping the curve and dragging a filter both convert the other way, so
    /// the two directions have to agree.
    func testFractionAndFrequencyAreInverses() {
        let axis = axis()
        for step in 0...40 {
            let fraction = Double(step) / 40
            let frequency = axis.frequency(atFraction: fraction)
            XCTAssertEqual(axis.fraction(of: frequency), fraction, accuracy: 0.0001)
        }
    }

    /// Below the lowest rung and above the highest it extrapolates using the
    /// neighbouring octave ratio, rather than clamping — otherwise a low shelf
    /// at 30 Hz would sit on top of the 32 Hz band.
    func testItExtrapolatesPastTheOutermostBands() {
        let axis = axis()
        XCTAssertLessThan(axis.fraction(of: 20), axis.fraction(of: anchors[0]))
        XCTAssertGreaterThan(
            axis.fraction(of: 20_000), axis.fraction(of: anchors[anchors.count - 2]))
    }

    /// The gutter is the strip the dB labels live in; the plot starts after it,
    /// and the band strip below reserves the same width so the two line up.
    func testTheGutterShiftsEveryPositionButNotTheProportions() {
        let plain = axis(width: 880, gutter: 0)
        let inset = axis(width: 880, gutter: 52)

        XCTAssertEqual(inset.plotWidth, 828)
        XCTAssertEqual(
            inset.x(anchors[0]), 52 + CGFloat(plain.fraction(of: anchors[0])) * 828, accuracy: 0.01)
        XCTAssertEqual(inset.fraction(of: 1_000), plain.fraction(of: 1_000), accuracy: 0.0001)
    }

    func testXIsClampedToThePlot() {
        let axis = axis(width: 880, gutter: 52)
        XCTAssertGreaterThanOrEqual(axis.x(1), 52)
        XCTAssertLessThanOrEqual(axis.x(200_000), 880)
    }

    /// A zero-width axis is what a view gets on its first layout pass, and it
    /// must not divide by it.
    func testAZeroWidthAxisIsHarmless() {
        let axis = axis(width: 0, gutter: 52)
        XCTAssertEqual(axis.plotWidth, 1)
        XCTAssertTrue(axis.x(1_000).isFinite)
    }
}
