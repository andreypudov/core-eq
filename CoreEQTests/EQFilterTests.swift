import Foundation
import Testing

/// The one type every other part of the app passes around: the editors write
/// it, the processor renders it, the graph draws it, and the disk stores it.
struct EQFilterTests {
    // MARK: - Kinds

    /// High and low pass cut by slope alone. The row and the graph node both
    /// hide gain for them, and `Biquad` never reads it — so this flag is the
    /// single place that decision is recorded.
    @Test func onlyGainBearingKindsUseGain() {
        #expect(EQFilter.Kind.bell.usesGain)
        #expect(EQFilter.Kind.lowShelf.usesGain)
        #expect(EQFilter.Kind.highShelf.usesGain)
        #expect(!EQFilter.Kind.highPass.usesGain)
        #expect(!EQFilter.Kind.lowPass.usesGain)
    }

    @Test func everyKindHasATitle() {
        for kind in EQFilter.Kind.allCases {
            #expect(!kind.title.isEmpty, "\(kind) has no name to show")
            #expect(kind.id == kind.rawValue)
        }
    }

    // MARK: - Bands

    @Test func aBandTakesItsFrequencyAndQFromTheLadder() {
        for slot in 0..<BuiltInProfiles.bandCount {
            let band = EQFilter.band(slot: slot, gain: 3)
            #expect(band.frequency == BuiltInProfiles.frequencies[slot])
            #expect(band.q == BuiltInProfiles.defaultQ)
            #expect(band.band == slot)
            #expect(band.isBand)
            #expect(band.gain == 3)
        }
    }

    /// Every rung is a bell, the ends included. `EQFilter.band` records why;
    /// this is the guard that keeps it that way.
    @Test func everyRungIsABell() {
        for slot in 0..<BuiltInProfiles.bandCount {
            #expect(EQFilter.band(slot: slot, gain: 3).kind == .bell)
        }
    }

    /// Lifting a band into the filter list must not change the sound: same
    /// kind, frequency, gain, Q, and colour — only the slot goes.
    @Test func unboundKeepsEverythingButTheSlot() {
        let band = EQFilter(
            kind: .lowShelf, frequency: 180, gain: -4, q: 0.8,
            isEnabled: false, band: 3, colorIndex: 5
        )
        let free = band.unbound()

        #expect(free.band == nil)
        #expect(!free.isBand)
        #expect(free.kind == band.kind)
        #expect(free.frequency == band.frequency)
        #expect(free.gain == band.gain)
        #expect(free.q == band.q)
        #expect(free.isEnabled == band.isEnabled)
        #expect(free.colorIndex == band.colorIndex)
    }

    // MARK: - Identity and equality

    /// Identity is per-instance and deliberately outside `==`: a chain decoded
    /// from disk has to compare equal to the one it was saved from, or the app
    /// would report a freshly launched preset as edited.
    @Test func equalityIgnoresIdentity() {
        let one = EQFilter(kind: .bell, frequency: 1_000, gain: 3, q: 1)
        let other = EQFilter(kind: .bell, frequency: 1_000, gain: 3, q: 1)

        #expect(one.id != other.id)
        #expect(one == other)
    }

    @Test func everyStoredPropertyCountsTowardsEquality() {
        let base = EQFilter(kind: .bell, frequency: 1_000, gain: 3, q: 1, band: 2, colorIndex: 1)

        var kind = base
        kind.kind = .lowShelf
        var frequency = base
        frequency.frequency = 1_001
        var gain = base
        gain.gain = 3.5
        var q = base
        q.q = 1.1
        var enabled = base
        enabled.isEnabled = false
        var slot = base
        slot.band = 3
        var colour = base
        colour.colorIndex = 4

        for (name, changed) in [
            ("kind", kind), ("frequency", frequency), ("gain", gain), ("q", q),
            ("isEnabled", enabled), ("band", slot), ("colorIndex", colour),
        ] {
            #expect(base != changed, "a change of \(name) went unnoticed")
        }
    }

    // MARK: - Coding

    @Test func codingRoundTrip() throws {
        let filter = EQFilter(
            kind: .highShelf, frequency: 9_000, gain: 2.5, q: 0.7,
            isEnabled: false, band: nil, colorIndex: 6
        )
        let decoded = try JSONDecoder().decode(
            EQFilter.self, from: JSONEncoder().encode(filter)
        )
        #expect(decoded == filter)
    }

    /// Every stored key is optional with a sensible default, so a preset
    /// written by an older version — before kinds, before colours — still
    /// loads instead of failing the whole file.
    @Test func decodingFillsInWhatOlderVersionsNeverWrote() throws {
        let json = Data(#"{"frequency": 500}"#.utf8)
        let decoded = try JSONDecoder().decode(EQFilter.self, from: json)

        #expect(decoded.frequency == 500)
        #expect(decoded.kind == .bell)
        #expect(decoded.gain == 0)
        #expect(decoded.q == BuiltInProfiles.defaultQ)
        #expect(decoded.isEnabled)
        #expect(decoded.band == nil)
        #expect(decoded.colorIndex == 0)
    }

    @Test func decodingWithoutAFrequencyFails() {
        #expect(throws: (any Error).self, "a filter with no frequency is not a filter") {
            try JSONDecoder().decode(EQFilter.self, from: Data(#"{"gain": 3}"#.utf8))
        }
    }
}
