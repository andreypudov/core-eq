import Foundation
import Testing

/// Two small helpers that everything else leans on: every gain the app accepts
/// passes through `clamped`, and every lookup into a chain of varying length
/// goes through `safe`.
struct ExtensionsTests {
    @Test func clampingHoldsValuesInsideTheRange() {
        #expect((-99.0).clamped(to: -12...12) == -12)
        #expect(99.0.clamped(to: -12...12) == 12)
        #expect(3.5.clamped(to: -12...12) == 3.5)
        #expect((-12.0).clamped(to: -12...12) == -12, "the bounds are inside the range")
        #expect(12.0.clamped(to: -12...12) == 12)
    }

    @Test func clampingLeavesTheValueItselfUntouched() {
        let value = 0.1 + 0.2
        #expect(
            value.clamped(to: 0...1) == value,
            "clamping rounded a value it should have passed through")
    }

    @Test func safeIndexingReturnsNilInsteadOfTrapping() {
        let chain = [1, 2, 3]
        #expect(chain[safe: 0] == 1)
        #expect(chain[safe: 2] == 3)
        #expect(chain[safe: 3] == nil)
        #expect(chain[safe: -1] == nil, "a negative index is a bug elsewhere, not a crash here")
        #expect([Int]()[safe: 0] == nil)
    }
}
