import SwiftUI

/// The number beside a knob: editable, committed on Return or on leaving the
/// field, with its unit shown inside the box.
///
/// The unit sits in the field rather than after it because the field is what
/// carries the value, and "50" followed by a loose "Hz" reads as two things
/// when the row already has six columns competing for the eye. Drawn rather
/// than `.roundedBorder` for the same reason: a table of bordered fields is a
/// row of boxes, and the quieter fill lets the knobs and the colour do the
/// pointing.
struct ValueField: View {
    let value: Double
    /// Shown inside the trailing edge — "Hz", "dB", or nothing for Q, which has
    /// no unit.
    let unit: String?
    let format: FloatingPointFormatStyle<Double>
    let isEnabled: Bool
    let accessibilityLabel: String
    let commit: (Double) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 3) {
            TextField(
                "",
                value: Binding(get: { value }, set: commit),
                format: format
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 11).monospacedDigit())
            .focused($isFocused)
            .disabled(!isEnabled)
            .accessibilityLabel(accessibilityLabel)

            if let unit {
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor : Theme.blockBorder,
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .opacity(isEnabled ? 1 : 0.5)
    }
}
