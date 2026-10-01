import Foundation
import Testing

/// Moving through a number field must never change the value it holds.
struct FieldCommitTests {
    private let wholeHertz = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
    private let frequency = FloatingPointFormatStyle<Double>.number.precision(
        .fractionLength(0...1))
    private let gain = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))

    /// The reported case: 70.8 Hz shown as "71" was stored as 71 on Tab.
    @Test func tabbingThroughARoundedFieldChangesNothing() {
        #expect(FieldCommit.value(71, replacing: 70.8, shownAs: wholeHertz) == nil)
    }

    @Test func typingADifferentNumberCommitsIt() {
        #expect(FieldCommit.value(72, replacing: 70.8, shownAs: wholeHertz) == 72)
        #expect(FieldCommit.value(80, replacing: 70.8, shownAs: frequency) == 80)
    }

    /// With a decimal shown, 70.8 reads as itself, and 71 is a real edit.
    @Test func theFrequencyFieldShowsTheDecimalItHas() {
        #expect(FieldCommit.value(70.8, replacing: 70.8, shownAs: frequency) == nil)
        #expect(FieldCommit.value(71, replacing: 70.8, shownAs: frequency) == 71)
        #expect(frequency.format(105) == "105")
    }

    /// A gain with more decimals than the field shows — 1.75 from a built-in —
    /// survives being tabbed through.
    @Test func aFinerGainSurvivesTheField() {
        #expect(FieldCommit.value(1.8, replacing: 1.75, shownAs: gain) == nil)
    }
}
