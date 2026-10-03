import Foundation
import Testing

struct AutoEQProfileBuilderTests {
    private static let model = "Alpha Headphones"

    @Test func buildsProfileFromEqualizedFilters() throws {
        let equalized = AutoEQEqualizedProfile(
            filters: [
                AutoEQEqualizedFilter(type: "PEAKING", fc: 105, q: 1.02, gain: 3.2),
                AutoEQEqualizedFilter(type: "LOW_SHELF", fc: 105, q: 0.70, gain: 5.5),
                AutoEQEqualizedFilter(type: "HIGH_SHELF", fc: 8_000, q: 0.70, gain: -3.1),
            ],
            preamp: -6.4)

        let profile = try AutoEQProfileBuilder.makeProfile(model: Self.model, equalized: equalized)

        #expect(profile.name == Self.model)
        #expect(!profile.isBuiltIn)
        #expect(profile.preamp == -6.4)
        // The file set its own preamp, so the computed trim is off.
        #expect(profile.autoGain == false)

        let free = profile.filters.filter { !$0.isBand }
        #expect(free.count == 3)
        #expect(free[0].kind == .bell)
        #expect(free[0].frequency == 105)
        #expect(free[0].gain == 3.2)
        #expect(free[0].q == 1.02)
        #expect(free[1].kind == .lowShelf)
        #expect(free[1].gain == 5.5)
        #expect(free[2].kind == .highShelf)
        #expect(free[2].gain == -3.1)
    }

    @Test func mapsPassFilters() throws {
        let equalized = AutoEQEqualizedProfile(
            filters: [
                AutoEQEqualizedFilter(type: "LOW_PASS", fc: 20_000, q: 0.70, gain: 0),
                AutoEQEqualizedFilter(type: "HIGH_PASS", fc: 20, q: 0.70, gain: 0),
            ],
            preamp: 0)

        let profile = try AutoEQProfileBuilder.makeProfile(model: Self.model, equalized: equalized)
        let free = profile.filters.filter { !$0.isBand }
        #expect(free.count == 2)
        #expect(free[0].kind == .lowPass)
        #expect(free[1].kind == .highPass)
    }

    @Test func skipsUnknownFilterTypes() throws {
        let equalized = AutoEQEqualizedProfile(
            filters: [
                AutoEQEqualizedFilter(type: "PEAKING", fc: 1_000, q: 1.0, gain: 2.0),
                AutoEQEqualizedFilter(type: "NOTCH", fc: 2_000, q: 4.0, gain: -6.0),
            ],
            preamp: 0)

        let profile = try AutoEQProfileBuilder.makeProfile(model: Self.model, equalized: equalized)
        #expect(profile.filters.filter { !$0.isBand }.count == 1)
    }

    @Test func throwsWhenEveryFilterIsUnsupported() {
        let equalized = AutoEQEqualizedProfile(
            filters: [AutoEQEqualizedFilter(type: "NOTCH", fc: 2_000, q: 4.0, gain: -6.0)],
            preamp: 0)

        do {
            _ = try AutoEQProfileBuilder.makeProfile(model: Self.model, equalized: equalized)
            Issue.record("expected makeProfile to throw")
        } catch {
            #expect(error as? AutoEQError == .unsupportedFilter("NOTCH"))
        }
    }

    @Test func buildsProfileFromPrecomputedText() throws {
        let text = """
            Preamp: -3.0 dB
            Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.50
            """
        let profile = try AutoEQProfileBuilder.makeProfile(
            model: Self.model, parametricEQText: text)
        #expect(profile.name == Self.model)
        #expect(profile.preamp == -3.0)
        #expect(profile.filters.filter { !$0.isBand }.count == 1)
    }
}
