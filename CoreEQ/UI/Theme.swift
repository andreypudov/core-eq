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
