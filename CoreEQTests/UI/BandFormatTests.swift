import Foundation
import Testing

/// The strings the axis, the sliders, the readouts, and the parametric fields
/// all share. They are shared precisely so two parts of the window can never
/// disagree about what a number is called.
struct BandFormatTests {
    @Test func frequenciesReadTheWayPeopleSayThem() {
        #expect(BandFormat.frequency(32) == "32")
        #expect(BandFormat.frequency(125) == "125")
        #expect(BandFormat.frequency(999) == "999")
        #expect(BandFormat.frequency(1_000) == "1k")
        #expect(BandFormat.frequency(16_000) == "16k")
        #expect(BandFormat.frequency(20_000) == "20k")
    }

    /// A kilohertz value that is not a whole number keeps one decimal rather
    /// than rounding to a different band.
    @Test func fractionalKilohertzKeepsADecimal() {
        #expect(BandFormat.frequency(1_500) == "1.5k")
        #expect(BandFormat.frequency(2_800) == "2.8k")
    }

    /// Every band on the ladder has to have a label; a blank one under a slider
    /// would be a slider nobody can identify.
    @Test func everyLadderFrequencyHasALabel() {
        for frequency in BuiltInProfiles.frequencies {
            #expect(!BandFormat.frequency(frequency).isEmpty)
        }
    }

    /// The sign carries information only when it is a boost, so an untouched
    /// band reads "0.0 dB" rather than "+0.0 dB".
    @Test func gainIsSignedOnlyWhenTheSignMeansSomething() {
        #expect(BandFormat.gain(4) == "+4.0 dB")
        #expect(BandFormat.gain(0) == "0.0 dB")
        #expect(BandFormat.gain(-3.5) == "-3.5 dB")

        // Every value the controls can produce lands on a tenth or a half, so
        // the only rounding that happens here is on a value typed into a field.
        // It goes half-to-even, which is what `%.1f` does: 4.25 shows as 4.2.
        #expect(BandFormat.gain(4.25) == "+4.2 dB")
        #expect(BandFormat.gain(4.26) == "+4.3 dB")
    }

    /// The scale beside the plot uses a true minus sign, not a hyphen: it sits
    /// under a plus sign in the same column and has to align with it.
    @Test func axisLabelsUseATrueMinusSign() {
        #expect(BandFormat.axisGain(12) == "+12 dB")
        #expect(BandFormat.axisGain(0) == "0 dB")
        #expect(BandFormat.axisGain(-12) == "\u{2212}12 dB")

        #expect(BandFormat.axisValue(12) == "+12")
        #expect(BandFormat.axisValue(0) == "0")
        #expect(BandFormat.axisValue(-12) == "\u{2212}12")
    }
}
