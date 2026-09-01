import Foundation
import Testing

/// The size the main window opens at.
///
/// Arithmetic nobody developing on a large display ever exercises: on any screen
/// with room the answer is the preferred size, and every interesting case is a
/// screen the author does not have.
struct MainWindowGeometryTests {

    /// A display with room gets the size the layout was designed for.
    @Test func aLargeScreenGetsThePreferredSize() {
        let size = MainWindowGeometry.openingSize(visibleFrame: CGSize(width: 3_440, height: 1_400))

        #expect(size == MainWindowGeometry.preferred)
    }

    /// The window arrives fully on screen rather than with its edges past the
    /// corner, so a display that cannot hold the preferred size gets less.
    @Test func aSmallerScreenIsKeptClearOfItsEdges() {
        let visible = CGSize(width: 1_280, height: 720)
        let size = MainWindowGeometry.openingSize(visibleFrame: visible)

        #expect(size.width <= visible.width - MainWindowGeometry.screenInset)
        #expect(size.height <= visible.height - MainWindowGeometry.screenInset)
    }

    /// The floor holds even when the screen is the reason it would be broken.
    ///
    /// Insetting from a small or scaled display asks for less than the fixed
    /// sections need — 1_024 wide leaves 944, under the 960 minimum — and a
    /// window opening below its own layout minimum is the one outcome worth
    /// ruling out here rather than leaving AppKit to clamp silently.
    @Test func aVerySmallScreenStillGetsTheMinimumSize() {
        let size = MainWindowGeometry.openingSize(visibleFrame: CGSize(width: 1_024, height: 600))

        #expect(size.width == MainWindowGeometry.minimum.width)
        #expect(size.height == MainWindowGeometry.minimum.height)
    }

    /// Each axis is capped on its own: a wide, short screen keeps its width.
    @Test func eachAxisIsCappedIndependently() {
        let size = MainWindowGeometry.openingSize(visibleFrame: CGSize(width: 2_560, height: 700))

        #expect(size.width == MainWindowGeometry.preferred.width)
        #expect(size.height == 620)
    }

    /// AppKit genuinely reports no main screen — during login, or with the lid
    /// shut on a Mac driving nothing. Opening at the preferred size beats
    /// opening at zero.
    @Test func noScreenFallsBackToThePreferredSize() {
        #expect(MainWindowGeometry.openingSize(visibleFrame: nil) == MainWindowGeometry.preferred)
    }

    /// The window is never offered a size its own minimum would reject.
    @Test func theOpeningSizeIsNeverBelowTheMinimum() {
        for width in stride(from: 640.0, through: 3_840.0, by: 64) {
            for height in stride(from: 480.0, through: 2_160.0, by: 64) {
                let size = MainWindowGeometry.openingSize(
                    visibleFrame: CGSize(width: width, height: height))
                #expect(size.width >= MainWindowGeometry.minimum.width)
                #expect(size.height >= MainWindowGeometry.minimum.height)
                #expect(size.width <= MainWindowGeometry.preferred.width)
                #expect(size.height <= MainWindowGeometry.preferred.height)
            }
        }
    }
}
