import SwiftUI

/// Output trim, beside the editing area.
///
/// Two filters can boost the same frequency, and the chain has no idea how much
/// headroom the source had — so a boosted preset can ask for more than there is
/// and clip. This is where it is given back. It sits next to the editor rather
/// than in the output row because it belongs to the sound the preset describes,
/// not to where that sound is going.
struct GlobalGainView: View {
    @ObservedObject var profileManager: ProfileManager
    let isEnabled: Bool

    @State private var isDragging = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 10) {
            Text("Global Gain")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 8) {
                VerticalGainSlider(
                    value: preamp,
                    range: BuiltInProfiles.preampRange,
                    step: 0.5,
                    isEnabled: isEnabled,
                    isActive: isDragging || isHovering,
                    onDragChange: { isDragging = $0 },
                    onReset: { profileManager.setPreamp(0) }
                )
                .frame(width: Theme.BandRow.columnWidth, height: sliderHeight)
                .onHover { isHovering = $0 }
                .accessibilityLabel("Global gain")
                .accessibilityValue(String(format: "%+.1f decibels", profileManager.currentPreamp))

                scale
            }

            TextField(
                "",
                value: Binding(
                    get: { profileManager.currentPreamp },
                    set: { profileManager.setPreamp($0) }
                ),
                format: .number.precision(.fractionLength(1))
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .controlSize(.small)
            .disabled(!isEnabled)
            .accessibilityLabel("Global gain in decibels")

            Text("Preamp")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: Theme.globalGainWidth)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    /// Marks at the two extremes and the reference, positioned with the same
    /// geometry the slider uses so they sit level with the knob travel.
    private var scale: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach([BuiltInProfiles.preampRange.upperBound, 0, BuiltInProfiles.preampRange.lowerBound], id: \.self) { dB in
                Text(BandFormat.axisGain(dB))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .offset(
                        y: VerticalGainSlider.knobCenterY(
                            for: dB, in: sliderHeight, range: BuiltInProfiles.preampRange
                        ) - 6
                    )
            }
        }
        .frame(height: sliderHeight)
        .accessibilityHidden(true)
    }

    /// Matches the band strip's slider so the two read as one scale when the
    /// Graphic tab is showing.
    private var sliderHeight: CGFloat { Theme.BandRow.sliderHeight }

    private var preamp: Binding<Double> {
        Binding(
            get: { profileManager.currentPreamp },
            set: { profileManager.setPreamp($0) }
        )
    }
}
