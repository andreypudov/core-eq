import Foundation

/// How a knob's parameter maps onto its 270° sweep, and which values it is
/// allowed to land on.
///
/// Two separate questions, deliberately answered separately:
///
/// *The sweep* is logarithmic for frequency and Q, because both are heard that
/// way — 50 Hz to 100 Hz is the octave 5 kHz to 10 kHz is, and Q 0.5 to 1 is
/// the same halving of bandwidth as 2 to 4. On a linear sweep of 20 Hz–20 kHz
/// the whole bass register would be the first two degrees. Gain is linear,
/// matching the sliders and the dB scale beside the graph.
///
/// *The values* are an explicit ladder — every value the control may hold, in
/// order — and one detent is one rung. That is what makes scrolling up and back
/// down land exactly where it started. The obvious implementation, multiplying
/// by a fixed ratio and rounding the result to two decimals, does not: rounding
/// breaks the symmetry between multiplying and dividing, so Q 1.00 nudged up
/// and back came home as 0.99, and a frequency could come back 8% adrift. A
/// ladder cannot drift, because coming down means stepping back onto the rung
/// you left.
///
/// The rungs are spaced in a parameter's own terms — 1 Hz in the bass and
/// 100 Hz at the top — so the resolution is fine where the ear is and coarse
/// where it isn't, and every rung is a number worth showing.
///
/// A ladder only holds its promise for values standing *on* it. Q learned this
/// the hard way: with rungs every 0.05 above 1, the app's own default of 1.41
/// sat between two of them, so a band's very first nudge up and back down came
/// home as 1.40. So a parameter whose values do not all fall on a coarse ladder
/// gets a fine one — every value its field can display — and takes several
/// rungs per detent instead.
struct KnobScale {
    let range: ClosedRange<Double>
    /// Whether the *sweep* is logarithmic. Says nothing about the rungs.
    let isLogarithmic: Bool
    /// Every value this control may hold, ascending.
    private let rungs: [Double]
    /// Rungs crossed by one detent. More than one where the ladder is finer
    /// than a useful step.
    private let rungsPerDetent: Int

    /// The three scales the parametric table uses.
    ///
    /// Built once rather than per row: a ladder is a few hundred values, and a
    /// row rebuilds its cells on every edit to the chain — including on every
    /// frame of a drag.
    static let filterFrequency = KnobScale.frequency(BuiltInProfiles.filterFrequencyRange)
    static let filterQ = KnobScale.q(BuiltInProfiles.filterQRange)
    static let filterGain = KnobScale.linear(BuiltInProfiles.gainRange, step: 0.5)

    /// Gain: half a decibel throughout, the same step the band sliders snap to,
    /// so scrolling a knob and scrolling a slider can't land between each
    /// other's values.
    static func linear(_ range: ClosedRange<Double>, step: Double) -> KnobScale {
        KnobScale(
            range: range,
            isLogarithmic: false,
            rungs: ladder(range, [(upTo: .infinity, step: step)]),
            rungsPerDetent: 1
        )
    }

    /// Frequency: three significant figures throughout, which puts a rung every
    /// 1 Hz in the bass and every 100 Hz at the top — around 1% to 5% of the
    /// value wherever you are on it.
    static func frequency(_ range: ClosedRange<Double>) -> KnobScale {
        KnobScale(
            range: range,
            isLogarithmic: true,
            rungs: ladder(range, [
                (upTo: 100, step: 1),
                (upTo: 1_000, step: 5),
                (upTo: 10_000, step: 50),
                (upTo: .infinity, step: 100),
            ]),
            rungsPerDetent: 1
        )
    }

    /// Q: a rung every hundredth, which is every value its field can show, and
    /// five of them to a detent.
    ///
    /// Not a coarser ladder with one rung per detent, which is the same 0.05
    /// step and reads identically — but only for a band whose Q is already a
    /// multiple of 0.05. The default is 1.41, and presets carry values like
    /// 0.707; those have to be able to come home too.
    static func q(_ range: ClosedRange<Double>) -> KnobScale {
        KnobScale(
            range: range,
            isLogarithmic: true,
            rungs: ladder(range, [(upTo: .infinity, step: 0.01)]),
            rungsPerDetent: 5
        )
    }

    // MARK: - The sweep

    /// Where on the sweep a value sits, 0 at the start and 1 at the end.
    func fraction(of value: Double) -> Double {
        let clamped = value.clamped(to: range)
        guard isLogarithmic else {
            let span = range.upperBound - range.lowerBound
            return span > 0 ? (clamped - range.lowerBound) / span : 0
        }
        let low = log(range.lowerBound)
        let span = log(range.upperBound) - low
        return span > 0 ? (log(clamped) - low) / span : 0
    }

    func value(at fraction: Double) -> Double {
        let f = fraction.clamped(to: 0...1)
        guard isLogarithmic else {
            return range.lowerBound + (range.upperBound - range.lowerBound) * f
        }
        let low = log(range.lowerBound)
        return exp(low + (log(range.upperBound) - low) * f)
    }

    // MARK: - The rungs

    /// The nearest value this control may hold. What a drag lands on, and what
    /// a number typed into the field is understood as once it is nudged.
    func snapped(_ value: Double) -> Double {
        let clamped = value.clamped(to: range)
        guard let index = nearestIndex(to: clamped) else { return clamped }
        return rungs[index]
    }

    /// `value` moved by `steps` detents.
    ///
    /// From a value standing on the ladder this is index arithmetic, so it is
    /// exactly reversible. From a value between rungs — one typed into the
    /// field with more precision than the field shows — the first detent puts
    /// it on the ladder in the direction asked, never backwards, and the rest
    /// follow from there.
    func stepped(_ value: Double, by steps: Int) -> Double {
        guard steps != 0, !rungs.isEmpty, let nearest = nearestIndex(to: value) else { return value }
        let epsilon = 1e-9
        let index: Int

        if abs(rungs[nearest] - value) < epsilon {
            index = nearest + steps * rungsPerDetent
        } else if steps > 0 {
            let above = rungs[nearest] > value ? nearest : nearest + 1
            index = above + (steps - 1) * rungsPerDetent
        } else {
            let below = rungs[nearest] < value ? nearest : nearest - 1
            index = below + (steps + 1) * rungsPerDetent
        }
        return rungs[min(max(index, 0), rungs.count - 1)]
    }

    /// Index of the rung closest to `value`, by binary search: this runs once
    /// per frame of every knob drag.
    private func nearestIndex(to value: Double) -> Int? {
        guard !rungs.isEmpty else { return nil }
        var low = 0
        var high = rungs.count - 1
        while low < high {
            let middle = (low + high) / 2
            if rungs[middle] < value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return low }
        return abs(rungs[low] - value) < abs(rungs[low - 1] - value) ? low : low - 1
    }

    /// The ladder for a range, given the step in force below each bound.
    ///
    /// Rungs land on multiples of the step in force, so the ladder reads as
    /// round numbers — 1050, 1100 — rather than as offsets from wherever the
    /// range happened to begin. Each is rounded to six decimals so that a value
    /// scrolled away and back is the *same* `Double` it was, not one an
    /// accumulated fraction away: the preset comparison that decides whether
    /// there are unsaved changes is exact.
    ///
    /// The next rung is found by rounding to the *nearest* multiple and adding
    /// one, never by flooring. A tenth divided by a hundredth is not an integer
    /// in binary — 0.29 / 0.01 is 28.999999999999996 — so flooring lands back
    /// on the rung the walk is standing on, and a loop that asks for the next
    /// rung and is handed the current one does not end. Rounding to nearest
    /// cannot do that: it always advances by at least half a step.
    private static func ladder(
        _ range: ClosedRange<Double>,
        _ resolutions: [(upTo: Double, step: Double)]
    ) -> [Double] {
        var rungs = [range.lowerBound]
        var value = range.lowerBound
        while value < range.upperBound {
            let step = resolutions.first { value < $0.upTo - 1e-9 }?.step
                ?? resolutions[resolutions.count - 1].step
            guard step > 0 else { break }
            let next = ((value / step).rounded() + 1) * step
            value = min((next * 1e6).rounded() / 1e6, range.upperBound)
            rungs.append(value)
        }
        return rungs
    }
}
