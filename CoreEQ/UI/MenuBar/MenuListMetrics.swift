import Foundation

/// Sizes shared by the inline choosers — `MenuRowView` for one row,
/// `MenuListView` for the list one unfolds into. Kept together here because a
/// row and the list it opens have to agree on them: a title that shifts
/// sideways or a row that changes height between the two states gives the whole
/// menu away as hand-drawn. `MenuBarController` documents how the chooser
/// behaves.
enum MenuListMetrics {
    /// Height of a row that is only text.
    static let rowHeight: CGFloat = 24
    /// Height of a row carrying a 28 pt device badge.
    static let deviceRowHeight: CGFloat = 34

    /// Leading gutter for the circular badge of a device row. Titles start after
    /// it, so the collapsed row and the options it opens share one text margin.
    /// Preset rows have no gutter — nothing marks the active one, so there is
    /// nothing to reserve room for.
    static let badgeGutter: CGFloat = 32

    /// How much of the list is on screen before it starts scrolling. The half
    /// row is deliberate: a row cut in two is what tells you there is more.
    static let maxVisibleRows: CGFloat = 5.5

    /// Inset of the highlight from the menu's edges, matching the rounded
    /// selection AppKit draws for standard rows.
    static let highlightInset: CGFloat = 6
    static let highlightCornerRadius: CGFloat = 5
}
