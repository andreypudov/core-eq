import SwiftUI
import Testing

/// The palette a parametric band is tagged with. Colour is presentation, but
/// it is presentation the user chose and the app stores by index, so the index
/// has to keep meaning the same thing.
struct BandColorTests {
    /// The model hands out colours by index and the palette resolves them.
    /// Nothing in the type system connects the two — only this.
    @Test func theModelAndThePaletteAgreeOnHowManyColoursThereAre() {
        #expect(
            BandColor.allCases.count == EQFilter.colorCount,
            "ProfileManager hands out \(EQFilter.colorCount) colours and the palette has \(BandColor.allCases.count)"
        )
    }

    /// A stored index is data from disk: it may be from a future version, or
    /// hand-edited. It has to resolve to a colour rather than trapping.
    @Test func anyStoredIndexResolvesToAColour() {
        #expect(BandColor.at(0) == BandColor.allCases[0])
        #expect(
            BandColor.at(EQFilter.colorCount - 1) == BandColor.allCases[EQFilter.colorCount - 1])
        #expect(BandColor.at(EQFilter.colorCount) == BandColor.allCases[0], "the palette wraps")
        #expect(BandColor.at(EQFilter.colorCount * 3 + 2) == BandColor.allCases[2])
        #expect(
            BandColor.at(-1) == BandColor.allCases[EQFilter.colorCount - 1],
            "a negative index wraps too")
    }

    /// Every colour is nameable: the swatch's tooltip and its accessibility
    /// label are the non-visual way to tell two bands apart.
    @Test func everyColourIsNamedAndDistinct() {
        let names = BandColor.allCases.map(\.name)
        #expect(!(names.contains { $0.isEmpty }))
        #expect(Set(names).count == names.count, "two colours share a name")
        #expect(BandColor.allCases.map(\.id) == BandColor.allCases.map(\.rawValue))
    }
}
