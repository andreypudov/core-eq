import SwiftUI

/// The number beside a knob: editable, committed on Return or on leaving the
/// field, adjustable by scroll wheel or trackpad, with its unit shown inside
/// the box.
///
/// The unit sits in the field rather than after it because the field is what
/// carries the value, and "50" followed by a loose "Hz" reads as two things
/// when the row already has six columns competing for the eye. Drawn rather
/// than `.roundedBorder` for the same reason: a table of bordered fields is a
/// row of boxes, and the quieter fill lets the knobs and the colour do the
/// pointing.
struct ValueField: View {
    /// Deliberately a binding rather than a value and a commit closure: a
    /// scroll steps from whatever the filter holds *now*. Several scroll events
    /// can arrive inside one frame, and stepping each of them from the value
    /// this view was built with would collapse a flick into a single detent and
    /// send a change of direction to the wrong rung.
    @Binding var value: Double
    /// Shown inside the trailing edge — "Hz", "dB", or nothing for Q, which has
    /// no unit.
    let unit: String?
    let format: FloatingPointFormatStyle<Double>
    /// The same scale its knob uses, so a scroll over the number and a scroll
    /// over the knob move the value by exactly the same detent.
    let scale: KnobScale
    let isEnabled: Bool
    let accessibilityLabel: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 3) {
            TextField("", value: $value, format: format)
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
        // The number is as much a control as the knob is, so it answers the
        // same gesture. Only scroll events land here — clicking still puts the
        // caret in the field, and a scroll anywhere else in the row still
        // scrolls the list.
        .scrollAdjustable(isEnabled: isEnabled) { steps in
            value = scale.stepped(value, by: steps)
        }
    }
}
