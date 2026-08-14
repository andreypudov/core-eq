import Foundation

/// Sizes shared by the inline choosers — `MenuRowView` for one row,
/// `MenuListView` for the list one unfolds into. Kept together here because a
/// row and the list it opens have to agree on them: a title that shifts
/// sideways or a row that changes height between the two states gives the whole
/// menu away as hand-drawn. `MenuBarController` documents how the chooser
/// behaves.
enum MenuListMetrics {
    /// Height of a row. One number, not one per section: the output chooser and
    /// the preset chooser are two instances of the same control, and a menu
    /// that draws them at different heights says they are different kinds of
    /// thing. The taller row is what the 28 pt badge needs.
    static let rowHeight: CGFloat = 34

    /// Leading gutter for a row's circular badge. Titles start after it, so the
    /// collapsed row and the options it opens share one text margin — and so do
    /// the two choosers.
    static let badgeGutter: CGFloat = 32

    /// Side of the badge itself: a device's symbol, or a preset's response
    /// curve.
    static let badgeSide: CGFloat = 28

    /// How much of the list is on screen before it starts scrolling. The half
    /// row is deliberate: a row cut in two is what tells you there is more.
    static let maxVisibleRows: CGFloat = 5.5

    /// Inset of the highlight from the menu's edges, matching the rounded
    /// selection AppKit draws for standard rows.
    static let highlightInset: CGFloat = 6
    static let highlightCornerRadius: CGFloat = 5

    /// The unfold, and the fold back up. Short on purpose: this sits between a
    /// click and the thing the click was for, so it has to read as the list
    /// arriving rather than as a wait. Opening is the slower of the two —
    /// something appearing deserves to be seen; something leaving does not.
    static let unfoldDuration: TimeInterval = 0.16
    static let foldDuration: TimeInterval = 0.10

    /// How far the list starts above where it lands, so it reads as coming out
    /// from under the row that opened it rather than as simply materialising.
    static let unfoldSlide: CGFloat = 6
}
