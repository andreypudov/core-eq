import XCTest

/// The one type every other part of the app passes around: the editors write
/// it, the processor renders it, the graph draws it, and the disk stores it.
final class EQFilterTests: XCTestCase {
    // MARK: - Kinds

    /// High and low pass cut by slope alone. The row and the graph node both
    /// hide gain for them, and `Biquad` never reads it — so this flag is the
    /// single place that decision is recorded.
    func testOnlyGainBearingKindsUseGain() {
        XCTAssertTrue(EQFilter.Kind.bell.usesGain)
        XCTAssertTrue(EQFilter.Kind.lowShelf.usesGain)
        XCTAssertTrue(EQFilter.Kind.highShelf.usesGain)
        XCTAssertFalse(EQFilter.Kind.highPass.usesGain)
        XCTAssertFalse(EQFilter.Kind.lowPass.usesGain)
    }

    func testEveryKindHasATitle() {
        for kind in EQFilter.Kind.allCases {
            XCTAssertFalse(kind.title.isEmpty, "\(kind) has no name to show")
            XCTAssertEqual(kind.id, kind.rawValue)
        }
    }

    // MARK: - Bands

    func testABandTakesItsFrequencyAndQFromTheLadder() {
        for slot in 0..<BuiltInProfiles.bandCount {
            let band = EQFilter.band(slot: slot, gain: 3)
            XCTAssertEqual(band.frequency, BuiltInProfiles.frequencies[slot])
            XCTAssertEqual(band.q, BuiltInProfiles.defaultQ)
            XCTAssertEqual(band.band, slot)
            XCTAssertTrue(band.isBand)
            XCTAssertEqual(band.gain, 3)
        }
    }

    /// Every rung is a bell, the ends included. `EQFilter.band` records why;
    /// this is the guard that keeps it that way.
    func testEveryRungIsABell() {
        for slot in 0..<BuiltInProfiles.bandCount {
            XCTAssertEqual(EQFilter.band(slot: slot, gain: 3).kind, .bell)
        }
    }

    /// Lifting a band into the filter list must not change the sound: same
    /// kind, frequency, gain, Q, and colour — only the slot goes.
    func testUnboundKeepsEverythingButTheSlot() {
        let band = EQFilter(
            kind: .lowShelf, frequency: 180, gain: -4, q: 0.8,
            isEnabled: false, band: 3, colorIndex: 5
        )
        let free = band.unbound()

        XCTAssertNil(free.band)
        XCTAssertFalse(free.isBand)
        XCTAssertEqual(free.kind, band.kind)
        XCTAssertEqual(free.frequency, band.frequency)
        XCTAssertEqual(free.gain, band.gain)
        XCTAssertEqual(free.q, band.q)
        XCTAssertEqual(free.isEnabled, band.isEnabled)
        XCTAssertEqual(free.colorIndex, band.colorIndex)
    }

    // MARK: - Identity and equality

    /// Identity is per-instance and deliberately outside `==`: a chain decoded
    /// from disk has to compare equal to the one it was saved from, or the app
    /// would report a freshly launched preset as edited.
    func testEqualityIgnoresIdentity() {
        let one = EQFilter(kind: .bell, frequency: 1_000, gain: 3, q: 1)
        let other = EQFilter(kind: .bell, frequency: 1_000, gain: 3, q: 1)

        XCTAssertNotEqual(one.id, other.id)
        XCTAssertEqual(one, other)
    }

    func testEveryStoredPropertyCountsTowardsEquality() {
        let base = EQFilter(kind: .bell, frequency: 1_000, gain: 3, q: 1, band: 2, colorIndex: 1)

        var kind = base; kind.kind = .lowShelf
        var frequency = base; frequency.frequency = 1_001
        var gain = base; gain.gain = 3.5
        var q = base; q.q = 1.1
        var enabled = base; enabled.isEnabled = false
        var slot = base; slot.band = 3
        var colour = base; colour.colorIndex = 4

        for (name, changed) in [
            ("kind", kind), ("frequency", frequency), ("gain", gain), ("q", q),
            ("isEnabled", enabled), ("band", slot), ("colorIndex", colour),
        ] {
            XCTAssertNotEqual(base, changed, "a change of \(name) went unnoticed")
        }
    }

    // MARK: - Coding

    func testCodingRoundTrip() throws {
        let filter = EQFilter(
            kind: .highShelf, frequency: 9_000, gain: 2.5, q: 0.7,
            isEnabled: false, band: nil, colorIndex: 6
        )
        let decoded = try JSONDecoder().decode(
            EQFilter.self, from: JSONEncoder().encode(filter)
        )
        XCTAssertEqual(decoded, filter)
    }

    /// Every stored key is optional with a sensible default, so a preset
    /// written by an older version — before kinds, before colours — still
    /// loads instead of failing the whole file.
    func testDecodingFillsInWhatOlderVersionsNeverWrote() throws {
        let json = Data(#"{"frequency": 500}"#.utf8)
        let decoded = try JSONDecoder().decode(EQFilter.self, from: json)

        XCTAssertEqual(decoded.frequency, 500)
        XCTAssertEqual(decoded.kind, .bell)
        XCTAssertEqual(decoded.gain, 0)
        XCTAssertEqual(decoded.q, BuiltInProfiles.defaultQ)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertNil(decoded.band)
        XCTAssertEqual(decoded.colorIndex, 0)
    }

    func testDecodingWithoutAFrequencyFails() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(EQFilter.self, from: Data(#"{"gain": 3}"#.utf8)),
            "a filter with no frequency is not a filter"
        )
    }
}
