import AppKit
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

    /// The band number has to fit beside its colour swatch on one line.
    ///
    /// This is measured, not asserted from a comment, because the failure was
    /// silent and off by half a point: the column held a swatch and one digit
    /// exactly, so bands 1–9 looked right and band 10 wrapped. The row is a
    /// fixed height, so a wrap is not a cramped label — it is a broken row.
    func testABandNumberFitsItsColumn() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        // The widest number the list can reach: filters are capped, and every
        // digit is the same width in a monospaced-digit face.
        let widest = String(repeating: "0", count: String(BuiltInProfiles.maxFreeFilters).count)
        let text = (widest as NSString).size(withAttributes: [.font: font]).width

        let available = Theme.FilterRow.Column.index
            - Theme.FilterRow.Column.indexSwatch
            - Theme.FilterRow.Column.indexGap

        XCTAssertGreaterThanOrEqual(
            available, text,
            "band \(BuiltInProfiles.maxFreeFilters) needs \(text) pt and the column leaves \(available) pt"
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
        XCTAssertGreaterThan(Theme.BandRow.minSliderHeight, Theme.BandRow.chromeHeight)
        XCTAssertGreaterThan(Theme.BandRow.minSliderHeight, Theme.BandRow.knobDiameter)
        XCTAssertGreaterThan(Theme.BandRow.columnWidth, Theme.BandRow.trackWidth)
    }

    // MARK: - The signal colour

    /// The response curve has to stay legible on both window appearances, and
    /// stay distinct from the accent the user picked.
    ///
    /// A dynamic colour is easy to get wrong in a way nothing catches: mismatch
    /// the appearance test and both branches return the same value, which looks
    /// fine on whichever appearance you happened to be running.
    func testTheSignalColourIsLegibleOnBothAppearances() throws {
        let dark = try resolve(Theme.signal, in: .darkAqua)
        let light = try resolve(Theme.signal, in: .aqua)

        XCTAssertNotEqual(
            dark, light,
            "one value is being returned for both appearances — the dynamic provider is not branching"
        )

        // 3:1 is what WCAG asks of a graphical object, and the curve is a 1.5 pt
        // line: the one element in the window that has to be followed by eye.
        let onDark = contrast(dark, try resolve(Color(nsColor: .windowBackgroundColor), in: .darkAqua))
        let onLight = contrast(light, try resolve(Color(nsColor: .windowBackgroundColor), in: .aqua))
        XCTAssertGreaterThan(onDark, 3.0, "the curve is hard to see on the dark window (\(onDark):1)")
        XCTAssertGreaterThan(onLight, 3.0, "the curve is hard to see on the light window (\(onLight):1)")
    }

    /// The whole point of the change: data and controls must never be the same
    /// colour, whatever accent the user has chosen.
    func testTheSignalColourIsNotAnAccentColour() throws {
        let signal = try resolve(Theme.signal, in: .darkAqua)
        for accent in [NSColor.systemGreen, .systemBlue, .systemPurple, .systemPink,
                       .systemRed, .systemOrange, .systemYellow, .systemGray] {
            let resolved = try resolve(Color(nsColor: accent), in: .darkAqua)
            XCTAssertGreaterThan(
                distance(signal, resolved), 0.12,
                "the curve is too close to the \(accent) accent to be told apart from a control"
            )
        }
    }

    // MARK: - Colour helpers

    private func resolve(_ color: Color, in appearance: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: appearance))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved)
    }

    private func luminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Straight-line distance in sRGB. Crude as colour science, adequate as a
    /// tripwire for "these two are the same colour".
    private func distance(_ a: NSColor, _ b: NSColor) -> Double {
        let dr = Double(a.redComponent - b.redComponent)
        let dg = Double(a.greenComponent - b.greenComponent)
        let db = Double(a.blueComponent - b.blueComponent)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
