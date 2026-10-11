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
            .exact

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

    @Test func preservesPublishedResponseWithoutClampingIndividualGains() throws {
        let filters = [
            AutoEQEqualizedFilter(type: "LOW_SHELF", fc: 105, q: 0.7, gain: 10),
            AutoEQEqualizedFilter(type: "PEAKING", fc: 64, q: 0.23, gain: -20),
            AutoEQEqualizedFilter(type: "PEAKING", fc: 412, q: 0.88, gain: 16),
        ]
        let profile = try AutoEQProfileBuilder.makeProfile(
            model: "Synthetic", equalized: .init(filters: filters, preamp: -6)
        ).exact
        for rate in [44_100.0, 48_000, 96_000] {
            for i in 0..<500 {
                let f = 20 * pow(1000, Double(i) / 499)
                let expected = filters.reduce(0) {
                    $0 + AutoEQLocalSolver.response($1, at: f, sampleRate: rate)
                }
                let actual = profile.filters.reduce(0) {
                    $0 + Biquad(filter: $1, sampleRate: rate).magnitudeDB(at: f, sampleRate: rate)
                }
                #expect(abs(actual - expected) < 1e-8)
            }
        }
    }

    @Test func representableButBeyondGraphicCorrectionIsDisclosedNotRejected() throws {
        // A −20 dB bell exactly on the 125 Hz rung: beyond the graphic ±12 dB
        // range, but representable as a free filter. It must preview with a
        // disclosure instead of being rejected.
        let candidates = try AutoEQProfileBuilder.makeProfile(
            model: "Adjusting",
            parametricEQText: "Preamp: -6 dB\nFilter 1: ON PK Fc 125 Hz Gain -20 dB Q 1.41")

        #expect(candidates.disclosure != .none)
        #expect(candidates.disclosure.requiresConfirmation)
        #expect(candidates.disclosure.clippableCount == 1)
        #expect(candidates.offersClipChoice)
        // Exact keeps the written gain; clipped returns it to the rung at ±12.
        #expect(candidates.exact.filters.filter { !$0.isBand }.first?.gain == -20)
        let slot = try #require(BuiltInProfiles.frequencies.firstIndex(of: 125))
        #expect(candidates.clipped.filters[slot].gain == -12)
    }

    @Test func unrepresentableCorrectionIsDisclosedNotRejected() throws {
        // Beyond the free-filter ±20 dB range and an out-of-range preamp: both
        // are disclosed rather than throwing.
        let candidates = try AutoEQProfileBuilder.makeProfile(
            model: "Loud",
            parametricEQText: "Preamp: -25 dB\nFilter 1: ON PK Fc 100 Hz Gain -25 dB Q 1.0")

        #expect(candidates.disclosure != .none)
        #expect(candidates.disclosure.hasLossyAdjustments)
        #expect(candidates.disclosure.requiresConfirmation)
        #expect(candidates.exact.preamp == -12)
        #expect(candidates.exact.filters.filter { !$0.isBand }.first?.gain == -20)
    }

    @Test func representableCorrectionHasNoDisclosure() throws {
        let candidates = try AutoEQProfileBuilder.makeProfile(
            model: Self.model,
            parametricEQText: "Preamp: -3 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.50")
        #expect(candidates.disclosure == .none)
        #expect(!candidates.disclosure.requiresConfirmation)
        #expect(!candidates.offersClipChoice)
    }

    @Test func mapsPassFilters() throws {
        let equalized = AutoEQEqualizedProfile(
            filters: [
                AutoEQEqualizedFilter(type: "LOW_PASS", fc: 20_000, q: 0.70, gain: 0),
                AutoEQEqualizedFilter(type: "HIGH_PASS", fc: 20, q: 0.70, gain: 0),
            ],
            preamp: 0)

        let profile = try AutoEQProfileBuilder.makeProfile(model: Self.model, equalized: equalized)
            .exact
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
            .exact
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
            model: Self.model, parametricEQText: text
        ).exact
        #expect(profile.name == Self.model)
        #expect(profile.preamp == -3.0)
        #expect(profile.filters.filter { !$0.isBand }.count == 1)
    }
}
