import Foundation
import Testing

/// The shape every chain in the app is guaranteed to hold.
///
/// The slider strip indexes straight into the array and the graph takes its
/// anchors from the ladder rather than deriving them, so everything downstream
/// depends on this being true of any chain that arrives from disk.
struct FilterChainTests {
    @Test func normalisingProducesTheLadderThenTheFreeFilters() {
        let chain = FilterChain.normalized([
            EQFilter(kind: .bell, frequency: 2_800, gain: 3, q: 1.2),
            EQFilter.band(slot: 4, gain: 5),
        ])

        #expect(chain.count == BuiltInProfiles.bandCount + 1)
        #expect(
            chain.prefix(BuiltInProfiles.bandCount).map(\.band)
                == Array(0..<BuiltInProfiles.bandCount))
        #expect(chain[4].gain == 5, "a band keeps its gain wherever it was stored")
        #expect(chain.last?.frequency == 2_800)
        #expect(chain.last?.band == nil)
    }

    @Test func anEmptyChainBecomesAFlatLadder() {
        let chain = FilterChain.normalized([])
        #expect(chain.count == BuiltInProfiles.bandCount)
        #expect(chain.allSatisfy { $0.gain == 0 && $0.isEnabled })
    }

    /// A band's frequency and Q come from the ladder, never from what was
    /// stored, so a preset written under an older ladder cannot label its slider
    /// differently from every other preset.
    @Test func bandsTakeTheLaddersOwnFrequencies() {
        var stale = EQFilter.band(slot: 9, gain: 3)
        stale.frequency = 15_000
        stale.q = 0.4

        let chain = FilterChain.normalized([stale])
        #expect(chain[9].frequency == BuiltInProfiles.frequencies[9])
        #expect(chain[9].q == BuiltInProfiles.defaultQ)
        #expect(chain[9].gain == 3)
    }

    /// The per-editor bypasses are gone, so a stored chain must never come back
    /// with a silent ladder and no control that could explain it.
    @Test func aLadderFilterAlwaysComesBackEnabled() {
        var off = EQFilter.band(slot: 2, gain: 6)
        off.isEnabled = false
        #expect(FilterChain.normalized([off])[2].isEnabled)
    }

    @Test func valuesAreClampedToWhatTheControlsCanHold() throws {
        let wild = EQFilter(kind: .bell, frequency: 90_000, gain: 99, q: 40)
        let chain = FilterChain.normalized([wild])
        let filter = try #require(chain.last)

        #expect(filter.frequency == BuiltInProfiles.filterFrequencyRange.upperBound)
        #expect(filter.gain == BuiltInProfiles.gainRange.upperBound)
        #expect(filter.q == BuiltInProfiles.filterQRange.upperBound)
    }

    /// A hand-edited defaults entry must not be able to push the chain past the
    /// render budget.
    @Test func freeFiltersAreCapped() {
        let many = (0..<(BuiltInProfiles.maxFreeFilters + 10)).map {
            EQFilter(frequency: Double(100 + $0), gain: 1, q: 1)
        }
        let chain = FilterChain.normalized(many)
        #expect(chain.count == BuiltInProfiles.bandCount + BuiltInProfiles.maxFreeFilters)
    }

    // MARK: - Tone

    @Test func toneOffsetsTheLadderAndLeavesFreeFiltersAlone() {
        let free = EQFilter(kind: .highShelf, frequency: 9_000, gain: 4, q: 0.7)
        let chain = FilterChain.normalized(BuiltInProfiles.emptyBandChain() + [free])

        let toned = FilterChain.applyingTone(bass: 6, mid: 0, treble: 0, to: chain)

        #expect(toned[0].gain > 5, "bass did not reach the lowest rung")
        #expect(toned[10].gain.isClose(to: 0, within: 0.001), "bass reached the top of the ladder")
        #expect(toned.last?.gain == 4, "a free filter is not the tone controls' business")
    }

    @Test func toneCannotPushABandPastItsRange() {
        var chain = BuiltInProfiles.emptyBandChain()
        for slot in chain.indices { chain[slot].gain = 10 }

        let toned = FilterChain.applyingTone(bass: 12, mid: 12, treble: 12, to: chain)
        #expect(toned.allSatisfy { $0.gain <= BuiltInProfiles.gainRange.upperBound })
    }

    @Test func aCentredToneChangesNothing() {
        let chain = BuiltInProfiles.all[3].filters
        #expect(FilterChain.applyingTone(bass: 0, mid: 0, treble: 0, to: chain) == chain)
    }
}
