import Foundation

/// One filter in the equalizer chain.
///
/// CoreEQ has a single chain. Eleven of its filters carry a `band` slot on the
/// ISO octave ladder: their frequency and Q come from `BuiltInProfiles`, can't
/// be edited, and they are presented as the band sliders. Every other filter is
/// free — the user chooses its kind, frequency, gain, and Q, and it appears in
/// the filter list and as a draggable node on the response graph.
///
/// The distinction is presentation only. `EQProcessor` receives one flat array
/// and treats every entry identically, which is what makes "graphic" and
/// "parametric" two ways of reaching one equalizer rather than two equalizers.
struct EQFilter: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case bell, lowShelf, highShelf, highPass, lowPass

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bell: return "Bell"
            case .lowShelf: return "Low Shelf"
            case .highShelf: return "High Shelf"
            case .highPass: return "High Pass"
            case .lowPass: return "Low Pass"
            }
        }

        /// Whether gain is a parameter of this kind. High and low pass cut by
        /// their slope alone — their gain is never read, and the list row and
        /// the graph node both stop offering it.
        var usesGain: Bool {
            switch self {
            case .bell, .lowShelf, .highShelf: return true
            case .highPass, .lowPass: return false
            }
        }
    }

    /// How many distinct colours a free filter can be tagged with, so the
    /// manager can hand a new one a colour nothing else is using. The palette
    /// itself is `BandColor`, which is UI; this is only its size.
    static let colorCount = 8

    var kind: Kind
    var frequency: Double
    var gain: Double
    var q: Double
    var isEnabled: Bool

    /// Index into `BandColor`. Presentation, not sound — it identifies this
    /// filter in the list and on the graph. Stored rather than derived from the
    /// filter's position so a band keeps its colour when the ones above it are
    /// removed.
    var colorIndex: Int

    /// Ladder slot, or nil for a free filter. This — not the frequency — is a
    /// band's identity, so the fixed slider strip has a stable mapping into a
    /// variable-length chain.
    var band: Int?

    /// Identity for SwiftUI lists.
    ///
    /// Deliberately outside `CodingKeys` *and* `==`: a chain decoded from disk
    /// has to compare equal to the one it was saved from, or `isModified` would
    /// report a freshly launched app as edited.
    let id = UUID()

    var isBand: Bool { band != nil }

    init(
        kind: Kind = .bell,
        frequency: Double,
        gain: Double,
        q: Double = BuiltInProfiles.defaultQ,
        isEnabled: Bool = true,
        band: Int? = nil,
        colorIndex: Int = 0
    ) {
        self.kind = kind
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.isEnabled = isEnabled
        self.band = band
        self.colorIndex = colorIndex
    }

    /// A filter occupying ladder slot `slot`, taking its frequency and Q from
    /// the ladder itself.
    static func band(slot: Int, gain: Double, isEnabled: Bool = true) -> EQFilter {
        EQFilter(
            kind: .bell,
            frequency: BuiltInProfiles.frequencies[slot],
            gain: gain,
            q: BuiltInProfiles.defaultQ,
            isEnabled: isEnabled,
            band: slot
        )
    }

    /// This filter as a free one: same kind, frequency, gain, and Q, no slot.
    ///
    /// The coefficients are unchanged, so lifting a band out of the slider strip
    /// leaves the sound identical. That is what makes it a move rather than a
    /// conversion.
    func unbound() -> EQFilter {
        EQFilter(
            kind: kind,
            frequency: frequency,
            gain: gain,
            q: q,
            isEnabled: isEnabled,
            band: nil,
            colorIndex: colorIndex
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind, frequency, gain, q, isEnabled, band, colorIndex
    }

    /// Every stored key is optional with a sensible default, so a preset written
    /// by a future version that adds a field still loads here.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .bell
        frequency = try container.decode(Double.self, forKey: .frequency)
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 0
        q = try container.decodeIfPresent(Double.self, forKey: .q) ?? BuiltInProfiles.defaultQ
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        band = try container.decodeIfPresent(Int.self, forKey: .band)
        colorIndex = try container.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
    }

    static func == (lhs: EQFilter, rhs: EQFilter) -> Bool {
        lhs.kind == rhs.kind
            && lhs.frequency == rhs.frequency
            && lhs.gain == rhs.gain
            && lhs.q == rhs.q
            && lhs.isEnabled == rhs.isEnabled
            && lhs.band == rhs.band
            // Colour counts as an edit: the working chain is only written to
            // disk while it differs from the preset, so a recoloured band that
            // compared equal would lose its colour on the next launch.
            && lhs.colorIndex == rhs.colorIndex
    }
}
