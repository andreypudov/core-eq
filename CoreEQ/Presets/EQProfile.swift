import Foundation

/// A named equalizer chain — the complete description of a sound.
///
/// A preset holds every filter, band and free alike. Selecting one therefore
/// replaces the whole chain: `Flat` is genuinely flat, rather than flat plus
/// whatever filters happened to be left over from the last preset.
struct EQProfile: Codable, Equatable, Identifiable {
    var name: String
    var filters: [EQFilter]

    /// Output trim applied after the chain, in dB.
    ///
    /// Two filters can boost the same frequency, so a chain can ask for more
    /// headroom than the source has. This is where that is given back, and it
    /// belongs to the preset because it is a property of the sound the preset
    /// describes.
    var preamp: Double = 0

    /// Whether the trim is computed from the chain rather than set by hand.
    ///
    /// A property of the preset, not a preference: whether *this* sound wants
    /// its loudness held constant is a decision about the sound.
    var autoGain = false

    /// Built-in profiles ship with CoreEQ and can't be renamed, edited in place,
    /// or deleted. User profiles support the full set of sidebar actions.
    ///
    /// Deliberately outside `CodingKeys`: only user profiles are ever persisted,
    /// so a decoded profile is always a user profile.
    var isBuiltIn = false

    var id: String { name }

    /// The eleven ladder filters, in slot order.
    var bandFilters: [EQFilter] {
        filters.filter(\.isBand).sorted { ($0.band ?? 0) < ($1.band ?? 0) }
    }

    /// Everything the user added by hand.
    var freeFilters: [EQFilter] {
        filters.filter { !$0.isBand }
    }

    init(
        name: String,
        filters: [EQFilter],
        preamp: Double = 0,
        autoGain: Bool = false,
        isBuiltIn: Bool = false
    ) {
        self.name = name
        self.filters = filters
        self.preamp = preamp
        self.autoGain = autoGain
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey {
        case name, filters, preamp, autoGain
        /// Presets written before the chain model: a flat array of ladder bands
        /// in slot order, with no kind, enabled flag, or slot index.
        case bands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        preamp = try container.decodeIfPresent(Double.self, forKey: .preamp) ?? 0

        if let filters = try container.decodeIfPresent([EQFilter].self, forKey: .filters) {
            self.filters = filters
        } else {
            let legacy = try container.decodeIfPresent([LegacyBand].self, forKey: .bands) ?? []
            self.filters = legacy.enumerated().map { slot, band in
                EQFilter(frequency: band.frequency, gain: band.gain, q: band.q, band: slot)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(filters, forKey: .filters)
        try container.encode(preamp, forKey: .preamp)
    }

    /// The shape of a band in presets saved by CoreEQ 1.x. Read once, at
    /// migration; never written.
    private struct LegacyBand: Decodable {
        var frequency: Double
        var gain: Double
        var q: Double
    }
}
