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

    var body: some View {
        // The same heading / track / caption rhythm a band column has — see
        // `Theme.BandRow` — so this track starts and ends exactly level with the
        // band tracks beside it.
        VStack(spacing: 2) {
            Text("Preamp")
                .font(.system(size: 13, weight: .semibold))
                .frame(height: Theme.BandRow.headingHeight)
                .accessibilityAddTraits(.isHeader)

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
                    // The scale is an overlay, so it costs no layout width: the
                    // track keeps the block's centreline and the heading and
                    // readout centre on it without being nudged.
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
                            profileManager.currentPreamp == 0
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
        .opacity(isEnabled ? 1.0 : 0.5)
        .help("Output trim applied after the whole chain — use it to give back headroom a boosted preset takes")
    }

    private var preamp: Binding<Double> {
        Binding(
            get: { profileManager.currentPreamp },
            set: { profileManager.setPreamp($0) }
        )
    }
}
