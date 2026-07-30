import XCTest

final class QuickToneTests: XCTestCase {
    func testWeightsCoverEveryBand() {
        let count = BuiltInProfiles.frequencies.count
        XCTAssertEqual(QuickTone.bassWeights.count, count)
        XCTAssertEqual(QuickTone.midWeights.count, count)
        XCTAssertEqual(QuickTone.trebleWeights.count, count)
    }

    func testNeutralControlsProduceNoOffset() {
        XCTAssertTrue(QuickTone.offsets(bass: 0, mid: 0, treble: 0).allSatisfy { $0 == 0 })
    }

    func testBassOnlyLiftsTheLowEnd() {
        let offsets = QuickTone.offsets(bass: 6, mid: 0, treble: 0)
        let frequencies = BuiltInProfiles.frequencies

        let lowest = offsets[frequencies.firstIndex(of: 32)!]
        let highest = offsets[frequencies.firstIndex(of: 20_000)!]
        XCTAssertGreaterThan(lowest, 0)
        XCTAssertEqual(highest, 0, "a bass control must not touch 20 kHz")
    }

    func testTrebleOnlyLiftsTheTopEnd() {
        let offsets = QuickTone.offsets(bass: 0, mid: 0, treble: 6)
        let frequencies = BuiltInProfiles.frequencies

        XCTAssertEqual(offsets[frequencies.firstIndex(of: 32)!], 0, "a treble control must not touch 32 Hz")
        XCTAssertGreaterThan(offsets[frequencies.firstIndex(of: 20_000)!], 0)
    }

    func testOffsetsAreAdditive() {
        let combined = QuickTone.offsets(bass: 4, mid: 2, treble: -3)
        let separate = zip(
            zip(QuickTone.offsets(bass: 4, mid: 0, treble: 0), QuickTone.offsets(bass: 0, mid: 2, treble: 0)).map(+),
            QuickTone.offsets(bass: 0, mid: 0, treble: -3)
        ).map(+)

        for (lhs, rhs) in zip(combined, separate) {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-12)
        }
    }
}
