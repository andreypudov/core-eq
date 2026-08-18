import SwiftUI

/// A bypass, drawn as the power button every equalizer already uses.
///
/// A switch is the control for a *preference* — a setting you are choosing. None
/// of CoreEQ's on/off controls are preferences: each one takes a part of the
/// chain out of the signal, which is a bypass, and the power glyph is the form
/// that says so in a vocabulary the audience already reads.
///
/// It is a `ToggleStyle` rather than a `Button` on purpose. A button that merely
/// looks like a toggle loses the on/off state VoiceOver announces, the keyboard
/// behaviour, and the accessibility traits — everything `.toggleStyle(.switch)`
/// supplies for free. Only the drawing changes here.
struct PowerToggleStyle: ToggleStyle {
    /// How much sound the button governs. Two of these can be on screen at once,
    /// and they are not equals.
    enum Weight {
        /// The whole equalizer. Carries a tinted well behind it, because it is
        /// the way back *on* and has to stay findable when everything else in
        /// the window is dimmed.
        case master
        /// One filter, in a table of them. A plain glyph: a well on every row
        /// would be a column of boxes competing with the values beside them.
        case band

        var diameter: CGFloat { self == .master ? 15 : 12 }
        var padding: CGFloat { self == .master ? 4 : 2 }
        var hasWell: Bool { self == .master }
    }

    var weight: Weight = .master

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: "power")
                .font(.system(size: weight.diameter, weight: .medium))
                .foregroundStyle(
                    configuration.isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
                )
                .padding(weight.padding)
                .background {
                    if weight.hasWell {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(configuration.isOn ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        configuration.isOn
                                            ? Color.accentColor.opacity(0.45)
                                            : Color.primary.opacity(0.12),
                                        lineWidth: 1
                                    )
                            )
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: configuration.isOn)
    }
}

extension ToggleStyle where Self == PowerToggleStyle {
    static var power: PowerToggleStyle { PowerToggleStyle(weight: .master) }
    static var bandPower: PowerToggleStyle { PowerToggleStyle(weight: .band) }
}
