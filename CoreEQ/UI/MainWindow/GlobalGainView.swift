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

    /// How far left of the track the Auto toggle sits. Mirrors the room the
    /// scale takes on the right, so the track stays on the block's centreline.
    private static let autoGutter: CGFloat = 20

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
                    // Auto on the left, the scale on the right, both as overlays
                    // so neither costs layout width: the track keeps the block's
                    // centreline and the caption centres on it without being
                    // nudged, and the two sides balance each other.
                    .overlay(alignment: .topLeading) {
                        autoToggle(trackHeight: trackHeight)
                            .offset(x: -Self.autoGutter)
                    }
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
                    .accessibilityValue(String(format: "%+.1f decibels", profileManager.currentPreamp))

                    // Where a band column carries its frequency; same font, so
                    // the two captions sit on one line.
                    Text(BandFormat.gain(profileManager.currentPreamp))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(
                            profileManager.currentPreamp == 0 && !profileManager.isAutoGain
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(Color.coreEQSignal)
                        )
                        .frame(height: Theme.BandRow.labelHeight)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: Theme.globalGainWidth - Theme.blockPadding * 2)
        // Fills the row so this block and the editor beside it are the same
        // height, and so the track above has a height to grow into.
        .frame(maxHeight: .infinity)
        .contentBlock()
        .borderLabel(alignment: .topLeading) {
            Text("Preamp")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .opacity(isEnabled ? 1.0 : 0.5)
        .help("Output trim applied after the whole chain — use it to give back headroom a boosted preset takes")
    }

    /// The mode switch for the trim, standing on its side beside the track it
    /// governs.
    ///
    /// Rotated because the column is 116 points wide and its one spare axis is
    /// the vertical one — a horizontal label would have taken a row from the
    /// rhythm this block shares with the band strip. Reading bottom to top is
    /// the rotation with a convention behind it: book spines, chart axes, and
    /// the vertical labels AppKit draws itself.
    ///
    /// While it is on, the slider is disabled rather than merely ignored: a
    /// control that moves under the pointer and springs back is worse than one
    /// that declines to move.
    private func autoToggle(trackHeight: CGFloat) -> some View {
        Button {
            profileManager.setAutoGain(!profileManager.isAutoGain)
        } label: {
            Text("AUTO")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .frame(width: 14, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(profileManager.isAutoGain ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            profileManager.isAutoGain ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12),
                            lineWidth: 1
                        )
                )
                .foregroundStyle(profileManager.isAutoGain ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // Centred on the track, so it reads as belonging to it rather than to
        // the caption or the border above.
        .offset(y: (trackHeight - 44) / 2)
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
