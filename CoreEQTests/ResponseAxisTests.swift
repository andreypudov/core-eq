import CoreGraphics
import Testing

/// Where a frequency sits on the plot.
///
/// The graph, the spectrum behind it, the grid, the handles and the hit testing
/// all ask this one type, so an error here would not look like a bug in any of
/// them — everything would simply be in the wrong place together, consistently.
/// It had no tests until it was given a file of its own.
struct ResponseAxisTests {
    private let anchors = BuiltInProfiles.frequencies

    private func axis(width: CGFloat = 880, gutter: CGFloat = 0) -> ResponseAxis {
        ResponseAxis(anchors: anchors, gutter: gutter, width: width)
    }

    /// The axis exists to line the graph up with the slider strip: band `i` sits
    /// at the centre of the `i`th of eleven equal columns, which is where its
    /// slider is.
    @Test func eachBandSitsOnItsSlidersCentreline() {
        let axis = axis()
        let slot = 1.0 / Double(anchors.count)

        for (index, frequency) in anchors.enumerated() {
            let expected = (Double(index) + 0.5) * slot
            #expect(
                axis.fraction(of: frequency).isClose(to: expected, within: 0.0001),
                "\(frequency) Hz is not above its own slider")
        }
    }

    @Test func theMappingIsMonotonic() {
        let axis = axis()
        var previous = -Double.infinity
        for frequency in stride(from: 20.0, through: 20_000.0, by: 25.0) {
            let fraction = axis.fraction(of: frequency)
            #expect(fraction > previous, "the axis folded back on itself at \(frequency) Hz")
            previous = fraction
        }
    }

    /// Between two rungs it interpolates logarithmically, so the geometric mean
    /// of a pair lands exactly halfway between them.
    @Test func frequenciesBetweenRungsInterpolateLogarithmically() {
        let axis = axis()
        for index in 0..<(anchors.count - 1) {
            let low = anchors[index]
            let high = anchors[index + 1]
            let middle = (low * high).squareRoot()
            let expected = (axis.fraction(of: low) + axis.fraction(of: high)) / 2
            #expect(axis.fraction(of: middle).isClose(to: expected, within: 0.0001))
        }
    }

    /// Sweeping the curve and dragging a filter both convert the other way, so
    /// the two directions have to agree.
    @Test func fractionAndFrequencyAreInverses() {
        let axis = axis()
        for step in 0...40 {
            let fraction = Double(step) / 40
            let frequency = axis.frequency(atFraction: fraction)
            #expect(axis.fraction(of: frequency).isClose(to: fraction, within: 0.0001))
        }
    }

    /// Below the lowest rung and above the highest it extrapolates using the
    /// neighbouring octave ratio, rather than clamping — otherwise a low shelf
    /// at 30 Hz would sit on top of the 32 Hz band.
    @Test func itExtrapolatesPastTheOutermostBands() {
        let axis = axis()
        #expect(axis.fraction(of: 20) < axis.fraction(of: anchors[0]))
        #expect(axis.fraction(of: 20_000) > axis.fraction(of: anchors[anchors.count - 2]))
    }

    /// The gutter is the strip the dB labels live in; the plot starts after it,
    /// and the band strip below reserves the same width so the two line up.
    @Test func theGutterShiftsEveryPositionButNotTheProportions() {
        let plain = axis(width: 880, gutter: 0)
        let inset = axis(width: 880, gutter: 52)

        #expect(inset.plotWidth == 828)
        #expect(
            inset.x(anchors[0]).isClose(
                to: 52 + CGFloat(plain.fraction(of: anchors[0])) * 828, within: 0.01))
        #expect(inset.fraction(of: 1_000).isClose(to: plain.fraction(of: 1_000), within: 0.0001))
    }

    @Test func xIsClampedToThePlot() {
        let axis = axis(width: 880, gutter: 52)
        #expect(axis.x(1) >= 52)
        #expect(axis.x(200_000) <= 880)
    }

    /// A zero-width axis is what a view gets on its first layout pass, and it
    /// must not divide by it.
    @Test func aZeroWidthAxisIsHarmless() {
        let axis = axis(width: 0, gutter: 52)
        #expect(axis.plotWidth == 1)
        #expect(axis.x(1_000).isFinite)
    }
}
