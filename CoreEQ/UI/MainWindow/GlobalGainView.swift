import SwiftUI

/// Output trim, in its own column to the right of the editing area.
///
/// Two filters can boost the same frequency, and the chain has no idea how much
/// headroom the source had — so a boosted preset can ask for more than there is
/// and clip. This is where it is given back. It sits beside the editor rather
/// than on the output row because it belongs to the sound the preset describes,
/// not to where that sound is going.
///
/// Named *Preamp* rather than *Global Gain*: it is the term Music.app uses on
/// the same control, so the audience that knows any equalizer already knows this
/// word, and it is also what AutoEQ and headphone-correction profiles call the
/// value — so an imported one will line up with the label without translation.
///
/// Drag the slider, or double-click it to return to 0 dB. The value reads out
/// under the track rather than in a field: the plot above already shows the
/// whole curve moving with it, so this only has to say where it is.
struct GlobalGainView: View {
    @ObservedObject var profileManager: ProfileManager
    let isEnabled: Bool

    @State private var isDragging = false
    @State private var isHovering = false

    private static let scaleGap: CGFloat = 6

    /// Width of the Auto switch — the word plus a little, centred under the
    /// track it governs.
    private static let autoWidth: CGFloat = 46

    var body: some View {
        // The same track / caption rhythm a band column has — see
        // `Theme.BandRow` — so this track starts and ends exactly level with the
        // band tracks beside it. The title is not in here: it is mounted on the
        // block's own border, as the editor's tabs are on theirs.
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let trackHeight = max(
                    proxy.size.height - Theme.BandRow.chromeHeight,
                    Theme.BandRow.minSliderHeight
                )
                VStack(spacing: 6) {
                    // On the same line as the band values, in the same font and
                    // the same colours, so the trim reads as one more number in
                    // that row rather than as a caption belonging to this block
                    // alone.
                    //
                    // Auto keeps it at full strength even at 0 dB: the trim is
                    // being computed then, and dimming it would say the control
                    // is idle at the moment it is doing the most work.
                    Text(BandFormat.gain(profileManager.currentPreamp))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(
                            profileManager.currentPreamp == 0 && !profileManager.isAutoGain
                                ? AnyShapeStyle(.tertiary)
                                : AnyShapeStyle(.secondary)
                        )
                        .frame(height: Theme.BandRow.valueHeight)
                        .accessibilityHidden(true)

                    VerticalGainSlider(
                        value: preamp,
                        range: BuiltInProfiles.preampRange,
                        step: 0.5,
                        isEnabled: isEnabled,
                        isActive: isDragging || isHovering,
                        onDragChange: { isDragging = $0 },
                        onReset: { profileManager.setPreamp(0) }
                    )
                    .frame(width: Theme.BandRow.columnWidth, height: trackHeight)
                    .disabled(profileManager.isAutoGain)
                    // The scale is an overlay so it costs no layout width: the
                    // track keeps the block's centreline and the rows above and
                    // below centre on it without being nudged.
                    .overlay(alignment: .topLeading) {
                        GainScale(
                            range: BuiltInProfiles.preampRange,
                            trackHeight: trackHeight,
                            side: .trailing,
                            showsUnit: false,
                            trackGap: Self.scaleGap
                        )
                        .offset(x: Theme.BandRow.columnWidth)
                    }
                    .onHover { isHovering = $0 }
                    .accessibilityLabel("Preamp")
                    .accessibilityValue(
                        String(format: "%+.1f decibels", profileManager.currentPreamp))

                    // The row a band column spends on its frequency. This
                    // column has no frequency to name, which is what makes room
                    // for the mode switch.
                    autoToggle
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: Theme.globalGainWidth - Theme.blockPadding * 2)
        // Fills the row so this block and the editor beside it are the same
        // height, and so the track above has a height to grow into.
        .frame(maxHeight: .infinity)
        // The same clearance the editor block gives its tabs. Both blocks lose
        // it from the top, so the tracks stay level.
        .padding(.top, Theme.borderLabelClearance)
        .contentBlock()
        // Centred on the block's top border, over the track it names.
        .borderLabel {
            Text("Preamp")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .opacity(isEnabled ? 1.0 : 0.5)
        .help(
            "Output trim applied after the whole chain — use it to give back headroom a boosted preset takes"
        )
    }

    /// The mode switch for the trim, in the row a band column spends naming its
    /// frequency.
    ///
    /// It stood on its side until every column gained a value row above its
    /// track: with the trim's own value moved up there, this row came free, and
    /// a switch that reads left to right needs no excuse made for it.
    ///
    /// While it is on, the slider is disabled rather than merely ignored: a
    /// control that moves under the pointer and springs back is worse than one
    /// that declines to move.
    private var autoToggle: some View {
        Button {
            profileManager.setAutoGain(!profileManager.isAutoGain)
        } label: {
            Text("AUTO")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                // Sized to the word, not to the column: a switch stretched the
                // full width would read as a bar across the bottom of the block
                // rather than as one control.
                .frame(width: Self.autoWidth, height: Theme.BandRow.labelHeight)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            profileManager.isAutoGain
                                ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            profileManager.isAutoGain
                                ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12),
                            lineWidth: 1
                        )
                )
                .foregroundStyle(
                    profileManager.isAutoGain
                        ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Automatic gain")
        .accessibilityValue(profileManager.isAutoGain ? "On" : "Off")
        .accessibilityAddTraits(profileManager.isAutoGain ? [.isSelected] : [])
        .help(
            profileManager.isAutoGain
                ? "The trim is computed from the chain — switch off to set it by hand"
                : "Compute the trim from the chain, so a boosted preset stays at the loudness it started from"
        )
    }

    private var preamp: Binding<Double> {
        Binding(
            get: { profileManager.currentPreamp },
            set: { profileManager.setPreamp($0) }
        )
    }
}
