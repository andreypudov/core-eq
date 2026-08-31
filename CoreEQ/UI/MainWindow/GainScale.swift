import SwiftUI

/// The dB scale beside a vertical gain track.
///
/// One control for both places a track appears — the band strip's axis and the
/// Preamp column — so the two can't drift apart in mark positions, wording, or
/// weight. It positions its marks with `VerticalGainSlider`'s own geometry, so a
/// mark sits exactly level with the knob travel it labels.
struct GainScale: View {
    /// Which side of the track the scale sits on.
    enum Side {
        case leading, trailing
    }

    let range: ClosedRange<Double>
    /// Height of the track this scale annotates.
    let trackHeight: CGFloat
    var side: Side = .leading
    /// The ends and the reference. Intermediate divisions were dropped with the
    /// tick dots: the curve is read against 0 dB, and more marks than this only
    /// compete with the tracks.
    var values: [Double] = [12, 0, -12]
    /// Whether the marks carry "dB". The band axis does; the Preamp column is
    /// narrow, sits under a heading that already says what it is, and reads
    /// clearly enough without.
    var showsUnit = true
    /// Gap between the scale and the track.
    var trackGap: CGFloat = 8

    private static let rowHeight: CGFloat = 13

    static func width(showsUnit: Bool) -> CGFloat {
        showsUnit ? 34 : 22
    }

    var body: some View {
        ZStack(alignment: side == .leading ? .topTrailing : .topLeading) {
            Color.clear
            ForEach(values, id: \.self) { gain in
                Text(showsUnit ? BandFormat.axisGain(gain) : BandFormat.axisValue(gain))
                    .font(Theme.Font.tick)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .frame(height: Self.rowHeight)
                    .offset(y: y(for: gain))
            }
        }
        .frame(width: Self.width(showsUnit: showsUnit), height: trackHeight)
        .padding(side == .leading ? .trailing : .leading, trackGap)
        .accessibilityHidden(true)
    }

    /// Top of a mark's row.
    ///
    /// Centred on the knob position it labels, then held inside the drawn track
    /// — without the clamp the end marks sit half a row past each end of the
    /// line, which reads as the scale being taller than the thing it measures.
    private func y(for gain: Double) -> CGFloat {
        let center = VerticalGainSlider.knobCenterY(for: gain, in: trackHeight, range: range)
        let track = VerticalGainSlider.trackBounds(in: trackHeight)
        return min(
            max(center - Self.rowHeight / 2, track.lowerBound),
            max(track.upperBound - Self.rowHeight, track.lowerBound)
        )
    }
}
