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
    /// Whether the trim is being computed rather than held.
    var autoGain: Bool

    init(
        profileName: String,
        filters: [EQFilter]? = nil,
        preamp: Double = 0,
        tone: [Double]? = nil,
        autoGain: Bool = true
    ) {
        self.profileName = profileName
        self.filters = filters
        self.preamp = preamp
        self.tone = tone
        self.autoGain = autoGain
    }

    /// Written before auto gain existed means the trim was set by hand.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileName = try container.decode(String.self, forKey: .profileName)
        filters = try container.decodeIfPresent([EQFilter].self, forKey: .filters)
        preamp = try container.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
        tone = try container.decodeIfPresent([Double].self, forKey: .tone)
        autoGain = try container.decodeIfPresent(Bool.self, forKey: .autoGain) ?? true
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
    var autoGain: Bool

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
        autoGain: Bool = true,
        alternate: WorkingState? = nil,
        liveSlot: ABSlot = .a
    ) {
        self.profileName = profileName
        self.filters = filters
        self.preamp = preamp
        self.tone = tone
        self.autoGain = autoGain
        self.alternate = alternate
        self.liveSlot = liveSlot
    }

    /// A state written before A/B has neither key; both defaults are the truth
    /// about it — one slot, and it is A.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileName = try container.decode(String.self, forKey: .profileName)
        filters = try container.decodeIfPresent([EQFilter].self, forKey: .filters)
        preamp = try container.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
        tone = try container.decodeIfPresent([Double].self, forKey: .tone)
        autoGain = try container.decodeIfPresent(Bool.self, forKey: .autoGain) ?? true
        alternate = try container.decodeIfPresent(WorkingState.self, forKey: .alternate)
        liveSlot = try container.decodeIfPresent(ABSlot.self, forKey: .liveSlot) ?? .a
    }

    /// The live slot as a value in its own right.
    var live: WorkingState {
        get {
            WorkingState(
                profileName: profileName, filters: filters,
                preamp: preamp, tone: tone, autoGain: autoGain
            )
        }
        set {
            profileName = newValue.profileName
            filters = newValue.filters
            preamp = newValue.preamp
            tone = newValue.tone
            autoGain = newValue.autoGain
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

extension DeviceEQState {
    /// What this state means as something playable, read against the presets
    /// that exist right now.
    ///
    /// Launch and a device switch both go through here. They used to carry a
    /// copy of these rules each, which had already drifted: a slot holding an
    /// explicit centred tone restored its edited chain on launch and the bare
    /// preset on a switch. One reading, one behaviour.
    struct Resolved {
        var profileName: String
        var filters: [EQFilter]
        var preamp: Double
        var bass: Double
        var mid: Double
        var treble: Double
        var autoGain: Bool
    }

    func resolved(against profiles: [EQProfile]) -> Resolved {
        // A preset that has since been deleted falls back to the default rather
        // than to nothing, so a stale slot can never leave the app with no sound
        // selected.
        let profile =
            profiles.first { $0.name == profileName }
            ?? profiles.first { $0.name == BuiltInProfiles.defaultProfileName }
            ?? profiles[0]

        var bass = 0.0
        var mid = 0.0
        var treble = 0.0
        if let saved = tone, saved.count == 3 {
            bass = saved[0].clamped(to: QuickTone.range)
            mid = saved[1].clamped(to: QuickTone.range)
            treble = saved[2].clamped(to: QuickTone.range)
        }
        let isToneNeutral = bass == 0 && mid == 0 && treble == 0

        let chain: [EQFilter]
        if !isToneNeutral {
            // Tone positions win: the chain is derived from them, so the popover
            // sliders and the audio cannot disagree about where the tone sits.
            chain = FilterChain.applyingTone(
                bass: bass, mid: mid, treble: treble, to: profile.filters)
        } else {
            chain = filters.map(FilterChain.normalized) ?? profile.filters
        }

        // A computed trim is recomputed rather than trusted: the stored number
        // was right for the chain as it stood, and the chain may have been
        // normalised on the way in.
        let trim =
            autoGain
            ? AutoGain.trim(for: chain)
            : preamp.clamped(to: BuiltInProfiles.preampRange)

        return Resolved(
            profileName: profile.name,
            filters: chain,
            preamp: trim,
            bass: bass,
            mid: mid,
            treble: treble,
            autoGain: autoGain
        )
    }
}
