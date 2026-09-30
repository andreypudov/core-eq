import Foundation
import Testing

/// An AutoEQ profile for a real pair of headphones, imported and compared
/// against the response AutoEQ publishes for it — the roadmap's test of whether
/// the preset format is really open.
///
/// The profile and the published points are AutoEq's (MIT), for the Sennheiser
/// HD 600 as measured by oratory1990: `results/oratory1990/over-ear/Sennheiser
/// HD 600/` in github.com/jaakkopasanen/AutoEq, fetched 2026-09-30. The points
/// are that folder's CSV, column `parametric_eq`: AutoEQ's own computed response
/// of these filters, without the preamp.
///
/// The response here is computed with `Biquad`, the same definition the engine
/// renders with and the graph draws, so this is the curve that is heard. Across
/// all 695 published frequencies it agreed within 0.064 dB at 44.1 kHz — the
/// rate AutoEQ computes at — and within 0.108 dB at 48 kHz, where the top
/// octave is shaped slightly differently by the sampling. Both are far below
/// what anyone can hear.
struct AutoEQResponseTests {
    static let profile = """
        Preamp: -6.3 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
        Filter 2: ON PK Fc 125 Hz Gain -2.7 dB Q 0.55
        Filter 3: ON PK Fc 8445 Hz Gain 3.3 dB Q 1.61
        Filter 4: ON PK Fc 522 Hz Gain 0.7 dB Q 1.02
        Filter 5: ON PK Fc 1298 Hz Gain -1.2 dB Q 2.14
        Filter 6: ON HSC Fc 10000 Hz Gain -3.1 dB Q 0.70
        Filter 7: ON PK Fc 3158 Hz Gain -1.8 dB Q 3.67
        Filter 8: ON PK Fc 2166 Hz Gain 0.9 dB Q 3.32
        Filter 9: ON PK Fc 6639 Hz Gain 2.2 dB Q 5.82
        Filter 10: ON PK Fc 5433 Hz Gain -1.2 dB Q 5.70
        """

    /// (frequency in Hz, published response in dB), spread across the range
    /// and through every filter's centre.
    static let published: [(Double, Double)] = [
        (20.0, 6.29), (49.96, 5.0), (105.37, 0.66), (124.79, -0.42),
        (299.53, -0.85), (522.93, 0.2), (998.46, -0.4), (1_293.26, -1.1),
        (2_169.69, 0.58), (3_166.72, -1.56), (5_419.55, -0.33), (6_612.88, 3.34),
        (8_480.57, 2.55), (10_043.58, 0.58), (16_032.2, -2.83), (19_955.54, -3.05),
    ]

    @Test func importsEveryFilterUnchanged() throws {
        let parsed = try ParametricEQParser.parse(text: Self.profile)
        #expect(parsed.filters.filter { !$0.isBand }.count == 10)
        #expect(parsed.preamp == -6.3)
        #expect(parsed.droppedFilterCount == 0)
        #expect(parsed.adjustedValueCount == 0)
    }

    @Test func matchesThePublishedResponse() throws {
        let rate = 44_100.0
        let biquads = try ParametricEQParser.parse(text: Self.profile).filters
            .map { Biquad(filter: $0, sampleRate: rate) }
        for (frequency, expected) in Self.published {
            let response = biquads.reduce(0) {
                $0 + $1.magnitudeDB(at: frequency, sampleRate: rate)
            }
            // The published values are rounded to 0.01 dB.
            #expect(
                abs(response - expected) < 0.1,
                "\(frequency) Hz: CoreEQ \(response) dB, AutoEQ \(expected) dB")
        }
    }
}
