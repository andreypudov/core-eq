import Foundation

/// Which of a device's two working states is being heard.
///
/// A and B are the same kind of thing, so the app never asks "is B in use" —
/// it asks which slot is live and treats the other as the one being compared
/// against.
enum ABSlot: String, Codable, Equatable {
    case a, b

    var other: ABSlot { self == .a ? .b : .a }

    /// What the control shows.
    var label: String { self == .a ? "A" : "B" }
}

/// One of a device's two working states: a preset, whatever has been changed
/// about it, the trim, and the tone positions.
///
/// Exactly what a device used to store in total. A/B did not add a concept —
/// it made the existing one countable.
struct WorkingState: Codable, Equatable {
    var profileName: String
    /// The chain, or nil when it still matches the preset.
    var filters: [EQFilter]?
    var preamp: Double
    /// `[bass, mid, treble]`, or nil when all three are centred.
    var tone: [Double]?

    init(profileName: String, filters: [EQFilter]? = nil, preamp: Double = 0, tone: [Double]? = nil) {
        self.profileName = profileName
        self.filters = filters
        self.preamp = preamp
        self.tone = tone
    }
}

/// Everything CoreEQ remembers for one output device.
///
/// macOS keeps volume per device — switch to headphones and you get the level
/// you last set for headphones — and equalization has the same shape: the curve
/// that suits headphones is not the one that suits laptop speakers. So the
/// preset in effect, any unsaved edits to it, the output trim, and the Quick EQ
/// tone positions all belong to a device rather than to the application.
///
/// The preset *library* is deliberately not per device. Presets are a shared
/// collection; only which one is playing, and what has been changed about it,
/// follows the hardware.
///
/// The A/B pair belongs here for the same reason everything else does: a
/// comparison set up on headphones should still be there when headphones come
/// back.
///
/// The live slot's fields sit at the top level rather than inside a wrapper, so
/// a state written before A/B existed decodes unchanged — it simply arrives with
/// no alternate and A live.
struct DeviceEQState: Codable, Equatable {
    var profileName: String
    var filters: [EQFilter]?
    var preamp: Double
    var tone: [Double]?

    /// The slot that is *not* being heard, or nil until the user has ever
    /// reached for the other one.
    var alternate: WorkingState?

    /// Which slot the top-level fields belong to. Switching swaps the two, so
    /// this is a label rather than a branch: the live state is always up here.
    var liveSlot: ABSlot

    init(
        profileName: String,
        filters: [EQFilter]? = nil,
        preamp: Double = 0,
        tone: [Double]? = nil,
        alternate: WorkingState? = nil,
        liveSlot: ABSlot = .a
    ) {
        self.profileName = profileName
        self.filters = filters
        self.preamp = preamp
        self.tone = tone
        self.alternate = alternate
        self.liveSlot = liveSlot
    }

    /// A state written before A/B has neither key; both defaults are the truth
    /// about it — one slot, and it is A.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileName = try container.decode(String.self, forKey: .profileName)
        filters = try container.decodeIfPresent([EQFilter].self, forKey: .filters)
        preamp = try container.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
        tone = try container.decodeIfPresent([Double].self, forKey: .tone)
        alternate = try container.decodeIfPresent(WorkingState.self, forKey: .alternate)
        liveSlot = try container.decodeIfPresent(ABSlot.self, forKey: .liveSlot) ?? .a
    }

    /// The live slot as a value in its own right.
    var live: WorkingState {
        get { WorkingState(profileName: profileName, filters: filters, preamp: preamp, tone: tone) }
        set {
            profileName = newValue.profileName
            filters = newValue.filters
            preamp = newValue.preamp
            tone = newValue.tone
        }
    }

    /// Puts the other slot in front, keeping the one that was live as the thing
    /// to come back to.
    ///
    /// A slot that has never been used starts as a copy of the one it is
    /// replacing, so reaching for B is silent: the comparison begins from where
    /// you are, and the first difference you hear is one you made.
    mutating func swapSlots() {
        let departing = live
        live = alternate ?? departing
        alternate = departing
        liveSlot = liveSlot.other
    }
}
