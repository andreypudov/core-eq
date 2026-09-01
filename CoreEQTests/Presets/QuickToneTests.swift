import Foundation
import Testing

struct QuickToneTests {
    @Test func weightsCoverEveryBand() {
        let count = BuiltInProfiles.frequencies.count
        #expect(QuickTone.bassWeights.count == count)
        #expect(QuickTone.midWeights.count == count)
        #expect(QuickTone.trebleWeights.count == count)
    }

    @Test func neutralControlsProduceNoOffset() {
        #expect(QuickTone.offsets(bass: 0, mid: 0, treble: 0).allSatisfy { $0 == 0 })
    }

    @Test func bassOnlyLiftsTheLowEnd() {
        let offsets = QuickTone.offsets(bass: 6, mid: 0, treble: 0)
        let frequencies = BuiltInProfiles.frequencies

        let lowest = offsets[frequencies.firstIndex(of: 32)!]
        let highest = offsets[frequencies.firstIndex(of: 20_000)!]
        #expect(lowest > 0)
        #expect(highest == 0, "a bass control must not touch 20 kHz")
    }

    @Test func trebleOnlyLiftsTheTopEnd() {
        let offsets = QuickTone.offsets(bass: 0, mid: 0, treble: 6)
        let frequencies = BuiltInProfiles.frequencies

        #expect(
            offsets[frequencies.firstIndex(of: 32)!] == 0, "a treble control must not touch 32 Hz")
        #expect(offsets[frequencies.firstIndex(of: 20_000)!] > 0)
    }

    @Test func offsetsAreAdditive() {
        let combined = QuickTone.offsets(bass: 4, mid: 2, treble: -3)
        let separate = zip(
            zip(
                QuickTone.offsets(bass: 4, mid: 0, treble: 0),
                QuickTone.offsets(bass: 0, mid: 2, treble: 0)
            ).map(+),
            QuickTone.offsets(bass: 0, mid: 0, treble: -3)
        ).map(+)

        for (lhs, rhs) in zip(combined, separate) {
            #expect(lhs.isClose(to: rhs, within: 1e-12))
        }
    }
}
