import SwiftUI

/// The app's design tokens, in one place so the sidebar, the graph, and the
/// band row can't drift apart.
enum Theme {
    /// CoreEQ's accent: Apple's System Green rather than the user's accent
    /// colour, so the curve, the handles, and the selected preset always read as
    /// the app's own green regardless of the system setting.
    static let accent = Color.green

    /// Width reserved at the left of the response plot for its dB labels, and
    /// at the left of the band slider row for its own scale.
    static let axisGutter: CGFloat = 52

    /// An 8 pt spacing system throughout the content column.
    enum Spacing {
        static let window: CGFloat = 28
        static let section: CGFloat = 24
        static let inner: CGFloat = 12
    }

    /// Inset between a content block's border and what it contains.
    static let blockPadding: CGFloat = 12

    /// Width of the Preamp column beside the editor: a centred track, plus room
    /// on the right for the scale that hangs off it, and nothing spare.
    static let globalGainWidth: CGFloat = 116

    /// Fixed height of the editing area, so switching tabs changes the controls
    /// and nothing else — no reflow, no jump in the graph above it.
    ///
    /// Sized to the tallest thing that lives there, which is the Global Gain
    /// card, not the band strip. Drop below that and the card clips instead of
    /// the graph giving up a few points.
    static let editorHeight: CGFloat = 248

    enum FilterRow {
        /// One row plus its spacing. The filter list multiplies this to size its
        /// scroll box, so the two must not drift apart.
        static let height: CGFloat = 28
    }

    /// The vertical rhythm the Band Levels and Preamp blocks share.
    ///
    /// Both are a heading, a strip of reserved space for the gain bubble, a
    /// track, and a caption. Driving both from these numbers is what keeps the
    /// preamp track starting and ending exactly level with the band tracks
    /// beside it.
    enum BandRow {
        /// Heading row, fixed so the two blocks' headings occupy the same height
        /// whether or not one of them carries a switch.
        static let headingHeight: CGFloat = 20
        /// Caption under a track — a frequency in the strip, the value in the
        /// preamp column.
        static let labelHeight: CGFloat = 14
        /// Everything in the column that isn't the track: the caption and the
        /// gap above it. Nothing is reserved above the track — the gain readout
        /// lives in the heading row, so the track starts right under it.
        static var chromeHeight: CGFloat { 6 + labelHeight }
        /// Floor for the track when the window is at its shortest.
        static let minSliderHeight: CGFloat = 96

        static let sliderHeight: CGFloat = 146
        /// Height the heading row's gain readout occupies, so the row doesn't
        /// change height as the readout comes and goes.
        static let readoutHeight: CGFloat = 18
        static let columnWidth: CGFloat = 26
        static let knobDiameter: CGFloat = 14
        static let trackWidth: CGFloat = 2
    }
}


extension View {
    /// A block in the content column: a border, and the window's own surface
    /// showing through.
    ///
    /// Deliberately no fill. These group controls; they are not surfaces of
    /// their own, and tinting each one turns a single canvas into a stack of
    /// panels. The response plot is the one exception — it *is* a surface, and
    /// keeps its fill.
    func contentBlock() -> some View {
        padding(Theme.blockPadding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
    }
}
