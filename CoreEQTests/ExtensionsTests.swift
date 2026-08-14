import XCTest

/// Two small helpers that everything else leans on: every gain the app accepts
/// passes through `clamped`, and every lookup into a chain of varying length
/// goes through `safe`.
final class ExtensionsTests: XCTestCase {
    func testClampingHoldsValuesInsideTheRange() {
        XCTAssertEqual((-99.0).clamped(to: -12...12), -12)
        XCTAssertEqual(99.0.clamped(to: -12...12), 12)
        XCTAssertEqual(3.5.clamped(to: -12...12), 3.5)
        XCTAssertEqual((-12.0).clamped(to: -12...12), -12, "the bounds are inside the range")
        XCTAssertEqual(12.0.clamped(to: -12...12), 12)
    }

    func testClampingLeavesTheValueItselfUntouched() {
        let value = 0.1 + 0.2
        XCTAssertEqual(value.clamped(to: 0...1), value, "clamping rounded a value it should have passed through")
    }

    func testSafeIndexingReturnsNilInsteadOfTrapping() {
        let chain = [1, 2, 3]
        XCTAssertEqual(chain[safe: 0], 1)
        XCTAssertEqual(chain[safe: 2], 3)
        XCTAssertNil(chain[safe: 3])
        XCTAssertNil(chain[safe: -1], "a negative index is a bug elsewhere, not a crash here")
        XCTAssertNil([Int]()[safe: 0])
    }
}
