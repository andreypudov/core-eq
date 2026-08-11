import XCTest

final class KnobScaleTests: XCTestCase {
    private let frequency = KnobScale.frequency(BuiltInProfiles.filterFrequencyRange)
    private let q = KnobScale.q(BuiltInProfiles.filterQRange)
    private let gain = KnobScale.linear(BuiltInProfiles.gainRange, step: 0.5)

    // MARK: - Scrolling up and back down comes home

    /// The property the whole design exists for. Scrolling a control up and
    /// then down by the same number of detents has to end where it started —
    /// in whatever mixture of batch sizes the trackpad delivers, since a flick
    /// arrives as several steps at once and a slow roll as one at a time.
    func testSteppingUpAndBackDownReturnsToTheStartingValue() {
        for (name, scale, starts) in [
            // Every one of these is a Q the app itself produces: the default a
            // band is created with, the values built-in presets carry, and the
            // ones the field can show.
            ("Q", q, [0.1, 0.5, 0.7, 0.99, 1.0, 1.2, 1.41, 2.95, 3.0, 5.0, 9.9]),
            ("frequency", frequency, [20, 32, 99, 100, 125, 995, 1_000, 2_500, 9_950, 10_000, 16_000]),
            ("gain", gain, [-12, -3.5, 0, 0.5, 4, 11.5]),
        ] as [(String, KnobScale, [Double])] {
            for start in starts {
                for up in 1...5 {
                    for batch in [1, 2, 3, 5] {
                        var value = start
                        for _ in 0..<up { value = scale.stepped(value, by: 1) }

                        // A walk that ran into the ceiling has nowhere to have
                        // come from, so coming down lands lower by design. That
                        // is the clamping behaviour, tested separately below.
                        if value == scale.range.upperBound { continue }

                        var remaining = up
                        while remaining > 0 {
                            let steps = min(batch, remaining)
                            value = scale.stepped(value, by: -steps)
                            remaining -= steps
                        }

                        XCTAssertEqual(
                            value, start, accuracy: 1e-9,
                            "\(name) drifted from \(start) after \(up) up and \(up) down in batches of \(batch)"
                        )
                    }
                }
            }
        }
    }

    /// The round trip has to be exact rather than merely close: `EQFilter`
    /// compares with `==`, and a value a fraction away would leave a preset
    /// reporting unsaved changes that the user cannot see or undo.
    func testTheReturnedValueIsBitForBitTheOneItStartedAs() {
        let start = 0.7
        let moved = q.stepped(start, by: 4)
        XCTAssertEqual(q.stepped(moved, by: -4), start)
    }

    // MARK: - Detents

    func testAStepAlwaysMovesTheValue() {
        for scale in [q, frequency, gain] {
            for value in [scale.range.lowerBound, scale.range.upperBound / 2] {
                XCTAssertGreaterThan(scale.stepped(value, by: 1), value)
            }
            XCTAssertLessThan(scale.stepped(scale.range.upperBound, by: -1), scale.range.upperBound)
        }
    }

    func testStepsStopAtTheEndsOfTheRange() {
        XCTAssertEqual(q.stepped(q.range.upperBound, by: 50), q.range.upperBound)
        XCTAssertEqual(frequency.stepped(frequency.range.lowerBound, by: -50), frequency.range.lowerBound)
    }

    /// A detent is a useful size at any point on the scale: a twentieth of a Q,
    /// half a decibel, and a frequency step of a few percent — single hertz in
    /// the bass, hundreds at the top of the range.
    func testResolutionFollowsTheValue() {
        XCTAssertEqual(q.stepped(0.5, by: 1), 0.55, accuracy: 1e-9)
        XCTAssertEqual(q.stepped(1.0, by: 1), 1.05, accuracy: 1e-9)
        XCTAssertEqual(q.stepped(5.0, by: 1), 5.05, accuracy: 1e-9)

        XCTAssertEqual(frequency.stepped(50, by: 1), 51, accuracy: 1e-9)
        XCTAssertEqual(frequency.stepped(1_000, by: 1), 1_050, accuracy: 1e-9)
        XCTAssertEqual(frequency.stepped(12_000, by: 1), 12_100, accuracy: 1e-9)

        XCTAssertEqual(gain.stepped(0, by: 1), 0.5, accuracy: 1e-9)
    }

    /// A value typed into the field sits between rungs. The first step has to
    /// move in the direction asked for rather than to the nearest rung, which
    /// could be behind it.
    func testSteppingFromBetweenRungsMovesInTheDirectionAsked() {
        XCTAssertEqual(frequency.stepped(1_234, by: 1), 1_250, accuracy: 1e-9)
        XCTAssertEqual(frequency.stepped(1_234, by: -1), 1_200, accuracy: 1e-9)
    }

    // MARK: - Snapping

    func testSnappingLandsOnARungInsideTheRange() {
        XCTAssertEqual(frequency.snapped(1_234), 1_250, accuracy: 1e-9)
        XCTAssertEqual(frequency.snapped(99_999), frequency.range.upperBound, accuracy: 1e-9)
        XCTAssertEqual(q.snapped(0), q.range.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(gain.snapped(4.3), 4.5, accuracy: 1e-9)
    }

    func testSnappingIsIdempotent() {
        for scale in [q, frequency, gain] {
            for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
                let once = scale.snapped(scale.value(at: fraction))
                XCTAssertEqual(scale.snapped(once), once, accuracy: 1e-12)
            }
        }
    }

    // MARK: - The sweep

    /// Frequency and Q are read logarithmically, so the middle of the sweep is
    /// the geometric middle of the range — a knob whose useful values all sit
    /// in its first few degrees is a knob nobody can set.
    func testLogarithmicSweepPutsTheGeometricMiddleAtTheMiddle() {
        XCTAssertEqual(frequency.fraction(of: 632.45), 0.5, accuracy: 0.01)
        XCTAssertEqual(q.fraction(of: 1.0), 0.5, accuracy: 0.01)
    }

    func testLinearSweepPutsZeroGainAtTheMiddle() {
        XCTAssertEqual(gain.fraction(of: 0), 0.5, accuracy: 1e-9)
    }

    func testTheSweepEndsAreTheRangeEnds() {
        for scale in [q, frequency, gain] {
            XCTAssertEqual(scale.value(at: 0), scale.range.lowerBound, accuracy: 1e-9)
            XCTAssertEqual(scale.value(at: 1), scale.range.upperBound, accuracy: 1e-9)
            XCTAssertEqual(scale.fraction(of: scale.range.lowerBound), 0, accuracy: 1e-9)
            XCTAssertEqual(scale.fraction(of: scale.range.upperBound), 1, accuracy: 1e-9)
        }
    }
}
