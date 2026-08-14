import SwiftUI
import XCTest

/// The layout arithmetic that has no runtime check.
///
/// The parametric table is built from fixed column widths, and the window can
/// be dragged down to `contentMinSize`. Nothing at runtime complains when those
/// two facts stop being compatible — the columns simply clip, on the narrowest
/// window, which is where it is least likely to be noticed.
final class ThemeTests: XCTestCase {
    /// The width the editor block actually has when the window is at its
    /// smallest, derived the way the window derives it.
    private var editorBlockWidth: CGFloat {
        let windowMinimum: CGFloat = 960          // AppDelegate.contentMinSize
        let sidebar: CGFloat = 216                // NSSplitViewItem.minimumThickness
        let content = windowMinimum - sidebar - Theme.Spacing.window * 2
        let editor = content - Theme.globalGainWidth - Theme.Spacing.inner
        return editor - Theme.blockPadding * 2
    }

    func testTheParametricTableFitsTheNarrowestWindow() {
        let columns = [
            Theme.FilterRow.Column.index,
            Theme.FilterRow.Column.enable,
            Theme.FilterRow.Column.type,
            Theme.FilterRow.Column.frequency,
            Theme.FilterRow.Column.gain,
            Theme.FilterRow.Column.q,
            Theme.FilterRow.Column.actions,
        ]
        let gaps = Theme.FilterRow.columnSpacing * CGFloat(columns.count - 1)
        let rowPadding: CGFloat = 8 * 2           // FilterRowView's horizontal inset
        let needed = columns.reduce(0, +) + gaps + rowPadding

        XCTAssertLessThanOrEqual(
            needed, editorBlockWidth,
            "the band row needs \(needed) pt and the block has \(editorBlockWidth) pt at the window's minimum width"
        )
    }

    /// Rows are sized in whole pitches, and the list divides by that pitch to
    /// decide how many fit. A zero or negative pitch would divide by zero.
    func testARowHasAPositivePitch() {
        XCTAssertGreaterThan(Theme.FilterRow.height, 0)
        XCTAssertGreaterThan(Theme.FilterRow.height + Theme.FilterRow.separator, Theme.FilterRow.height)
        XCTAssertGreaterThan(Theme.FilterRow.knobDiameter, 0)
        XCTAssertLessThan(
            Theme.FilterRow.knobDiameter, Theme.FilterRow.height,
            "a knob taller than its row would be clipped by it"
        )
    }

    /// The editing area is a fixed height so switching tabs moves nothing. It
    /// has to hold the column titles, at least one band, and the Add Band row.
    func testTheEditorIsTallEnoughForTheTableItHolds() {
        let chrome = Theme.blockPadding * 2 + Theme.BandRow.headingHeight + Theme.FilterRow.headerHeight
        let addRow: CGFloat = 8 + 20
        XCTAssertGreaterThan(
            Theme.editorHeight - chrome - addRow, Theme.FilterRow.height,
            "the editing area cannot show a single band row"
        )
    }

    /// The band strip and the Preamp column are laid out from the same numbers
    /// so their tracks start and end level. If the chrome ever exceeds the
    /// height, the track gets a negative size.
    func testTheBandColumnLeavesRoomForItsTrack() {
        XCTAssertGreaterThan(Theme.BandRow.sliderHeight, Theme.BandRow.chromeHeight)
        XCTAssertGreaterThan(Theme.BandRow.minSliderHeight, Theme.BandRow.knobDiameter)
        XCTAssertGreaterThan(Theme.BandRow.columnWidth, Theme.BandRow.trackWidth)
    }
}
