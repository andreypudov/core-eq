import Foundation
import Testing

/// The fields beside the knobs write a signed number the same way the readouts
/// and scales around them do — sign in front — in every language.
struct LeftToRightNumberFormatTests {
    private let gain = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        .sign(strategy: .always(includingZero: false))

    private func format(_ locale: String) -> LeftToRightNumberFormat {
        LeftToRightNumberFormat(gain.locale(Locale(identifier: locale)))
    }

    /// Arabic's format leads with an Arabic Letter Mark, which moves the sign
    /// behind the number. It is gone; a left-to-right mark leads instead.
    @Test func arabicKeepsItsDigitsAndLosesItsSignMark() {
        let shown = format("ar_SA").format(4)
        #expect(shown == "\u{200E}+\u{0664}\u{066B}\u{0660}")
        #expect(!shown.unicodeScalars.contains { $0.value == 0x061C })
    }

    /// A left-to-right language gets exactly what its locale writes.
    @Test func otherLanguagesReadAsBefore() {
        #expect(format("en_US").format(-3.5) == "-3.5")
        #expect(format("fr_FR").format(4) == "+4,0")
    }

    /// What the field shows, it reads back.
    @Test func whatIsShownParsesBack() throws {
        for locale in ["ar_SA", "en_US", "fr_FR", "ru_RU", "zh_Hans_CN"] {
            let style = format(locale)
            for value in [4.0, -3.5, 0.0, 12.5] {
                #expect(
                    try style.parseStrategy.parse(style.format(value)) == value,
                    "\(locale) \(value)")
            }
        }
    }

    /// Typed text needs no marks: plain digits parse in Arabic too.
    @Test func typedTextParsesWithoutMarks() throws {
        let arabic = format("ar_SA").parseStrategy
        #expect(try arabic.parse("+4") == 4)
        #expect(try arabic.parse("\u{0664}\u{066B}\u{0665}") == 4.5)
    }
}
