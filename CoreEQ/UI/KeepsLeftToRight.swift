import SwiftUI

extension View {
    /// Lays this view out left to right in every language, Arabic included.
    ///
    /// A right-to-left language mirrors the window — the header, the tabs, the
    /// order of the table's columns — and that is right for everything that
    /// reads. It is wrong for what measures: the frequency axis runs low to
    /// high left to right in every audio tool and on every graph with a
    /// numeric axis, the slider strip has to stay under the graph it mirrors,
    /// a knob turns clockwise to raise its value whoever is turning it, and a
    /// readout keeps its sign in front of its number (“+4.0 dB”, not
    /// “dB 4.0+”). Those views use this. The numbers inside still follow the
    /// user's locale; see `BandFormat`.
    func keepsLeftToRight() -> some View {
        environment(\.layoutDirection, .leftToRight)
    }
}

/// A number format that keeps the sign in front of the number in every
/// language, for the fields beside the knobs.
///
/// Arabic's own format puts an Arabic Letter Mark before the sign, which pulls
/// the sign to the right of the number — correct in running Arabic text, but
/// the readouts, scales, and graph around these fields put it in front, and
/// one window should not write a sign two ways. The marks are removed, and in
/// a right-to-left language a left-to-right mark leads instead, so a number
/// with no letter in it ("+٤٫٠") still reads left to right. Elsewhere nothing
/// is added: the mark is invisible but not free, and it moved the text of a
/// left-to-right field by a fraction of a pixel. The digits and the decimal
/// separator stay the locale's. Parsing removes the marks again, so the field accepts what it
/// shows, and anything else the locale's parser accepts.
struct LeftToRightNumberFormat: ParseableFormatStyle {
    var base: FloatingPointFormatStyle<Double>

    init(_ base: FloatingPointFormatStyle<Double>) {
        self.base = base
    }

    var parseStrategy: Strategy { Strategy(base: base.parseStrategy) }

    func format(_ value: Double) -> String {
        let text = Self.withoutMarks(base.format(value))
        return base.locale.language.characterDirection == .rightToLeft ? "\u{200E}" + text : text
    }

    struct Strategy: ParseStrategy {
        var base: FloatingPointParseStrategy<FloatingPointFormatStyle<Double>>

        func parse(_ value: String) throws -> Double {
            try base.parse(LeftToRightNumberFormat.withoutMarks(value))
        }
    }

    /// Arabic Letter Mark, left-to-right mark, right-to-left mark.
    static func withoutMarks(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter { ![0x061C, 0x200E, 0x200F].contains($0.value) }))
    }
}
