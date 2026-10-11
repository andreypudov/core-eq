import Foundation

/// One value an import changed, or would change, to make a correction fit
/// CoreEQ's limits.
///
/// The fields are pure values — what was written, what is stored, and which
/// limit did the adjusting — so a view can render them without reaching back
/// into the parser and a test can assert on them without a window.
struct ImportAdjustment: Equatable, Identifiable {
    enum Kind: String, Equatable {
        /// A free filter gain beyond ±20 dB, clamped into range.
        case gain
        /// A free filter Q outside 0.1–10.
        case q
        /// A free filter frequency outside 20 Hz–20 kHz.
        case frequency
        /// The output trim outside ±12 dB.
        case preamp
        /// A filter trimmed away to honour the free-filter budget.
        case droppedFilter
        /// A bell beyond the graphic ±12 dB range: kept exact as a free filter,
        /// or clipped back onto its rung when the user chooses to.
        case keptBeyondBandRange

        /// Whether choosing keep-exact still loses something. A value kept
        /// beyond the graphic range is disclosed but not altered, so it is the
        /// one kind that is not lossy.
        var isLossy: Bool { self != .keptBeyondBandRange }
    }

    /// Which filter an adjustment belongs to: its position, shape, and kind,
    /// enough for a view to name it. Nil for the chain-level preamp.
    struct FilterIdentity: Equatable {
        let index: Int
        let frequency: Double
        let q: Double
        let kind: EQFilter.Kind
    }

    let kind: Kind
    let filter: FilterIdentity?
    /// The value as written, or nil when there was none — a dropped filter has
    /// no stored value, and an absent preamp was never written.
    let original: Double?
    /// The value as stored, or nil when the filter was dropped. Equal to
    /// `original` for `.keptBeyondBandRange`.
    let adjusted: Double?
    /// The CoreEQ limit responsible, phrased for display.
    let limit: String

    var id: String { "\(kind.rawValue)-\(filter?.index ?? -1)" }
}

/// How far a set of adjustments moves the response, in dB, over the audio band.
///
/// Both figures are nil together when the intended chain cannot be rendered at
/// all — a non-physical Q or a frequency past the engine's ceiling — because a
/// comparison against a chain that has no response would be meaningless.
struct ImportImpact: Equatable {
    /// Root-mean-square difference across the band.
    let rmsDB: Double?
    /// Largest absolute difference at any point in the band.
    let maxDB: Double?

    var isMeasurable: Bool { rmsDB != nil && maxDB != nil }

    /// An import that changed nothing audible.
    static let none = ImportImpact(rmsDB: 0, maxDB: 0)
    /// An import whose impact could not be measured.
    static let unmeasurable = ImportImpact(rmsDB: nil, maxDB: nil)
}

/// What the user may do about a profile that CoreEQ can only import with
/// adjustments.
enum ImportChoice: Equatable {
    /// Keep every representable value exact; anything beyond the graphic range
    /// becomes a free filter.
    case keepExact
    /// Clip the beyond-band values to ±12 dB, using a rung when it is free.
    case clipBeyondBandRange
}

/// Everything an import would change, with the impact of each choice.
struct ImportDisclosure: Equatable {
    let adjustments: [ImportAdjustment]
    /// As-written to exact: the adjustments that apply no matter what.
    let impact: ImportImpact
    /// Exact to clipped: the impact of choosing to clip.
    let clipImpact: ImportImpact

    /// Whether any adjustment alters a value. A value merely kept beyond the
    /// graphic range is disclosed but preserved, so it does not count.
    var hasLossyAdjustments: Bool { adjustments.contains { $0.kind.isLossy } }

    /// How many values could be clipped into the graphic range.
    var clippableCount: Int {
        adjustments.filter { $0.kind == .keptBeyondBandRange }.count
    }

    /// Whether the import needs the user's confirmation before it commits.
    var requiresConfirmation: Bool { hasLossyAdjustments || clippableCount > 0 }

    static let none = ImportDisclosure(adjustments: [], impact: .none, clipImpact: .none)
}

/// The two chains an import could become, and the disclosure that describes the
/// choice between them.
struct ImportCandidates: Equatable {
    /// Representable values exact; beyond-band values kept as free filters.
    let exact: EQProfile
    /// Beyond-band bells clipped to ±12 dB, using a rung when it is free.
    let clipped: EQProfile
    let disclosure: ImportDisclosure

    /// Whether there is a real choice: the two chains differ.
    var offersClipChoice: Bool { clipped != exact }
}

/// Measures how far one chain's response is from another's.
///
/// A pure function over the same `Biquad` the engine runs, so the number shown
/// is what the audio path will do rather than an approximation of it.
enum ImportImpactCalculator {
    struct Result: Equatable {
        let rmsDB: Double
        let maxDB: Double
    }

    /// Whether a filter has a response that can be evaluated at `sampleRate`.
    ///
    /// Says nothing about whether the filter is audible — a 0 dB bell is
    /// renderable and silent — only that its coefficients are well-defined.
    static func isRenderable(_ filter: EQFilter, sampleRate: Double) -> Bool {
        if !filter.isEnabled
            || (filter.kind.usesGain && abs(filter.gain) <= Biquad.negligibleGainDB)
        {
            return true
        }
        return filter.frequency.isFinite && filter.frequency > 0
            && filter.frequency < sampleRate * Biquad.nyquistCeiling
            && filter.q.isFinite && filter.q > 0
            && filter.gain.isFinite
    }

    /// The RMS and maximum difference, in dB, between `intended` and
    /// `committed` over log-uniform points in `band`.
    ///
    /// Returns nil when either chain holds a filter that cannot be rendered, so
    /// callers can say the impact is unmeasurable rather than invent a number.
    static func difference(
        from intended: EQProfile,
        to committed: EQProfile,
        sampleRate: Double,
        band: ClosedRange<Double> = 20...20_000,
        pointCount: Int = 512
    ) -> Result? {
        guard
            intended.filters.allSatisfy({ isRenderable($0, sampleRate: sampleRate) }),
            committed.filters.allSatisfy({ isRenderable($0, sampleRate: sampleRate) })
        else {
            return nil
        }

        let intendedBiquads = intended.filters.map { Biquad(filter: $0, sampleRate: sampleRate) }
        let committedBiquads = committed.filters.map {
            Biquad(filter: $0, sampleRate: sampleRate)
        }

        var sumSquares = 0.0
        var maxAbs = 0.0
        let points = logUniformPoints(in: band, count: pointCount)
        for frequency in points {
            let intendedDB = intendedBiquads.reduce(intended.preamp) {
                $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate)
            }
            let committedDB = committedBiquads.reduce(committed.preamp) {
                $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate)
            }
            let delta = intendedDB - committedDB
            sumSquares += delta * delta
            maxAbs = max(maxAbs, abs(delta))
        }
        return Result(rmsDB: (sumSquares / Double(points.count)).squareRoot(), maxDB: maxAbs)
    }

    /// Points spaced evenly in log-frequency, so each octave is represented in
    /// proportion to how it is heard.
    private static func logUniformPoints(
        in band: ClosedRange<Double>, count: Int
    ) -> [Double] {
        guard count > 1 else { return [band.lowerBound] }
        let low = log10(band.lowerBound)
        let high = log10(band.upperBound)
        return (0..<count).map { index in
            pow(10, low + (high - low) * Double(index) / Double(count - 1))
        }
    }
}
