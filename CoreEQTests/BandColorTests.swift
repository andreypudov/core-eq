import SwiftUI
import XCTest

/// The palette a parametric band is tagged with. Colour is presentation, but
/// it is presentation the user chose and the app stores by index, so the index
/// has to keep meaning the same thing.
final class BandColorTests: XCTestCase {
    /// The model hands out colours by index and the palette resolves them.
    /// Nothing in the type system connects the two — only this.
    func testTheModelAndThePaletteAgreeOnHowManyColoursThereAre() {
        XCTAssertEqual(
            BandColor.allCases.count, EQFilter.colorCount,
            "ProfileManager hands out \(EQFilter.colorCount) colours and the palette has \(BandColor.allCases.count)"
        )
    }

    /// A stored index is data from disk: it may be from a future version, or
    /// hand-edited. It has to resolve to a colour rather than trapping.
    func testAnyStoredIndexResolvesToAColour() {
        XCTAssertEqual(BandColor.at(0), BandColor.allCases[0])
        XCTAssertEqual(BandColor.at(EQFilter.colorCount - 1), BandColor.allCases[EQFilter.colorCount - 1])
        XCTAssertEqual(BandColor.at(EQFilter.colorCount), BandColor.allCases[0], "the palette wraps")
        XCTAssertEqual(BandColor.at(EQFilter.colorCount * 3 + 2), BandColor.allCases[2])
        XCTAssertEqual(BandColor.at(-1), BandColor.allCases[EQFilter.colorCount - 1], "a negative index wraps too")
    }

    /// Every colour is nameable: the swatch's tooltip and its accessibility
    /// label are the non-visual way to tell two bands apart.
    func testEveryColourIsNamedAndDistinct() {
        let names = BandColor.allCases.map(\.name)
        XCTAssertFalse(names.contains { $0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count, "two colours share a name")
        XCTAssertEqual(BandColor.allCases.map(\.id), BandColor.allCases.map(\.rawValue))
    }
}
