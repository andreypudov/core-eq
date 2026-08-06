import SwiftUI

/// The app's design tokens, in one place so the sidebar, the graph, and the
/// band row can't drift apart.
enum Theme {
    /// CoreEQ's accent: Apple's System Green rather than the user's accent
    /// colour, so the curve, the handles, and the selected preset always read as
    /// the app's own green regardless of the system setting.
    static let accent = Color.green

    /// Width reserved at the left of the response plot for its dB labels. The
    /// band slider row reserves the same, so every band's slider stays directly
    /// under its point on the curve — the two are only aligned because they
    /// share this number.
    static let axisGutter: CGFloat = 52

    /// An 8 pt spacing system throughout the content column.
    enum Spacing {
        static let window: CGFloat = 28
        static let section: CGFloat = 24
        static let inner: CGFloat = 12
    }

    /// Width of the Global Gain column beside the editor.
    ///
    /// The graph carries the same trailing inset, so the band sliders stay
    /// directly under their points on the curve — the alignment the whole
    /// window is built on.
    static let globalGainWidth: CGFloat = 132

    /// Fixed height of the editing area, so switching tabs changes the controls
    /// and nothing else — no reflow, no jump in the graph above it.
    ///
    /// Sized to the tallest thing that lives there, which is the Global Gain
    /// card at ~249 pt, not the band strip at ~218. Drop below that and the card
    /// clips instead of the graph giving up a few points.
    static let editorHeight: CGFloat = 256

    enum FilterRow {
        /// One row plus its spacing. The filter list multiplies this to size its
        /// scroll box, so the two must not drift apart.
        static let height: CGFloat = 28
    }

    enum BandRow {
        static let sliderHeight: CGFloat = 146
        /// Just clears the gain bubble. Any taller and it reads as a gap between
        /// the "Band Levels" heading and the row it labels.
        static let readoutHeight: CGFloat = 24
        static let columnWidth: CGFloat = 26
        static let knobDiameter: CGFloat = 14
        static let trackWidth: CGFloat = 2
    }
}
