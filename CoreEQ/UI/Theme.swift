import AppKit
import SwiftUI

/// The app's design tokens, in one place so the sidebar, the graph, and the
/// band row can't drift apart.
enum Theme {
    /// The colour of CoreEQ's *data* — the response curve, its handles, and the
    /// values those handles carry. Fixed rather than the user's accent, the way
    /// Activity Monitor's graphs and Battery's charts are fixed: a reading
    /// shouldn't change meaning because someone picked a different accent.
    ///
    /// Controls are deliberately *not* this colour. Switches, sliders, the tab
    /// switcher, and list selection all take the system accent, so the window
    /// says "system utility" first and "CoreEQ" second.
    ///
    /// It used to be `Color.green`, which said the same thing and did the
    /// opposite: on a Mac with the green accent — the default on none of them,
    /// but common — the curve, the selected tab, the sidebar selection and every
    /// switch were one colour, and the accent stopped distinguishing anything.
    /// Amber belongs to no accent, so the separation is now real.
    ///
    /// Two values, because one cannot serve both grounds: measured against the
    /// window's own background, `#E8A33D` scores 7.2:1 on the dark appearance and
    /// 2.0:1 on the light one. `ThemeTests` holds both above the 3:1 that
    /// graphical objects need.
    static let signal = Color(nsColor: NSColor(name: "CoreEQSignal") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.910, green: 0.639, blue: 0.239, alpha: 1)  // #E8A33D
            : NSColor(srgbRed: 0.588, green: 0.365, blue: 0.071, alpha: 1)  // #965D12
    })

    /// Border shared by every block and by the plot, so the plot reads as one of
    /// them rather than as a panel with different rules.
    static let blockBorder = Color.primary.opacity(0.10)

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

    /// Width of the output device control in the header. Fixed rather than
    /// sized to the device name, so it stays on the column's centreline instead
    /// of shifting every time the device changes.
    static let outputControlWidth: CGFloat = 220

    /// Height of the header row, set by the large pop-up button in it.
    static let headerHeight: CGFloat = 32

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
        /// scroll box, so the two must not drift apart. Set by the knobs, which
        /// are the tallest thing in a row.
        static let height: CGFloat = 36

        static let knobDiameter: CGFloat = 24

        /// Height of the column-title row above the list.
        static let headerHeight: CGFloat = 18

        /// Hairline between two rows. Part of a row's pitch, so the list can
        /// size itself to whole rows.
        static let separator: CGFloat = 1

        /// Narrowest a gap between two columns may be. Reached only at the
        /// window's minimum width, where the editor block is about 536 points
        /// wide and the columns, their gaps, and the row's own padding claim 526
        /// of it. Widen a column and the table starts clipping on a 960-point
        /// window.
        static let columnSpacing: CGFloat = 8

        /// Widest a gap may grow to.
        ///
        /// The gaps are flexible between these two bounds, so the width a wider
        /// window gives the table is shared by every column instead of pooling
        /// in front of the last one. The ceiling is what stops that from
        /// continuing on a very wide window until the row reads as scattered
        /// controls rather than a table.
        static let columnSpacingMax: CGFloat = 28

        /// Fixed column widths, shared by the title row and every band row so
        /// the two line up without a `Grid` spanning the scroll view between
        /// them.
        ///
        /// Each is sized to its widest content, not to its title: "20000 Hz",
        /// "+12.0 dB", "10.00", and "High Shelf" are what these have to hold.
        enum Column {
            /// Colour swatch and band number, up to two digits.
            ///
            /// 34 held the swatch and one digit exactly, and wrapped the second:
            /// two monospaced digits at this size measure 14.6 pt and what was
            /// left over was 14. `ThemeTests` now measures it rather than
            /// trusting the arithmetic in this comment.
            static let index: CGFloat = 38
            /// The swatch button: an 8 pt circle inside a 3 pt hit-target
            /// padding, and the gap between it and the number.
            static let indexSwatch: CGFloat = 14
            static let indexGap: CGFloat = 6
            static let enable: CGFloat = 30
            static let type: CGFloat = 100
            static let frequency: CGFloat = 94
            static let gain: CGFloat = 92
            static let q: CGFloat = 76
            /// Just the delete button: there is no power icon, because the
            /// Enable switch two columns back is already that control.
            static let actions: CGFloat = 24
        }
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
        /// gap above it. Nothing is reserved above the track — a band's value
        /// is drawn at its own handle, over the track, so it costs no layout.
        static var chromeHeight: CGFloat { 6 + labelHeight }
        /// Floor for the track when the window is at its shortest.
        static let minSliderHeight: CGFloat = 96

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
                    .strokeBorder(Theme.blockBorder, lineWidth: 1)
            )
    }
}
