import Foundation

/// How large the main window opens.
///
/// The minimum is what the fixed sections actually need; every point above it
/// goes to the frequency response graph, which is the point of the window.
/// Header, editing area, and padding come to ~400 pt — the band strip spends 40
/// of that on `Theme.BandRow.chromeHeight`, a value row above each track and a
/// caption below. The rest is the graph, which has a 120 pt floor.
///
/// Separated from the window it sizes so the arithmetic can be checked at every
/// display size, including the ones nobody developing on a large screen ever
/// sees.
enum MainWindowGeometry {

    /// Below this the fixed sections start overlapping, so the window refuses to
    /// go smaller whatever the screen says.
    static let minimum = CGSize(width: 960, height: 540)

    /// What it opens at when there is room.
    static let preferred = CGSize(width: 1_120, height: 760)

    /// Kept clear of the screen edges, so the window always arrives fully on
    /// screen rather than with its corners past the edge.
    static let screenInset: CGFloat = 80

    /// The opening content size on a screen whose usable area is `visibleFrame`.
    ///
    /// Nil when no screen can be read — a state AppKit genuinely reports — and
    /// the preferred size is the only sensible guess.
    ///
    /// The floor is applied last and deliberately: capping to the screen can ask
    /// for less than the window's own minimum on a small or scaled display, and
    /// a window opening below the size its layout needs is the one outcome worth
    /// ruling out here rather than leaving to AppKit to clamp silently.
    static func openingSize(visibleFrame: CGSize?) -> CGSize {
        guard let visibleFrame else { return preferred }
        return CGSize(
            width: max(minimum.width, min(preferred.width, visibleFrame.width - screenInset)),
            height: max(minimum.height, min(preferred.height, visibleFrame.height - screenInset))
        )
    }
}
