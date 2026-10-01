import Foundation

/// Whether an edit in a number field should be written back to the filter.
///
/// A SwiftUI `TextField(value:format:)` parses what it *shows* and writes that
/// back whenever it loses focus, edited or not. A filter at 70.8 Hz shown with
/// no decimals is "71", so tabbing through the parametric editor set it to
/// 71 Hz — the preset turned Edited and Revert lit up while nothing had been
/// typed. Every imported AutoEQ profile has frequencies like that.
///
/// The rule: a field commits only when its text differs from what it was
/// showing. Moving through a field is never an edit; typing a different number
/// always is.
enum FieldCommit {
    /// The value to store, or nil to leave the stored one exactly as it is.
    static func value(
        _ parsed: Double, replacing current: Double,
        shownAs format: FloatingPointFormatStyle<Double>
    ) -> Double? {
        format.format(parsed) == format.format(current) ? nil : parsed
    }
}
