import Foundation

struct AutoEQBassBoost: Codable, Hashable, Sendable {
    var fc: Double
    var q: Double
    var gain: Double
}

struct AutoEQCurve: Codable, Hashable, Sendable {
    var frequency: [Double]
    var raw: [Double]

    var isValid: Bool {
        frequency.count == raw.count && frequency.count >= 2
            && frequency.allSatisfy { $0.isFinite && $0 > 0 }
            && raw.allSatisfy { $0.isFinite }
            && zip(frequency, frequency.dropFirst()).allSatisfy { $0 < $1 }
    }

    func value(at f: Double) -> Double {
        if f <= frequency[0] { return raw[0] }
        if f >= frequency.last! { return raw.last! }
        var lo = 0
        var hi = frequency.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frequency[mid] <= f { lo = mid } else { hi = mid }
        }
        let t = log(f / frequency[lo]) / log(frequency[hi] / frequency[lo])
        return raw[lo] + t * (raw[hi] - raw[lo])
    }

    static func csv(_ data: Data) throws -> Self {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutoEQError.malformedData
        }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let header = lines.first else { throw AutoEQError.malformedData }
        let columns = header.trimmingCharacters(in: .whitespacesAndNewlines).components(
            separatedBy: ",")
        guard let fi = columns.firstIndex(of: "frequency"), let ri = columns.firstIndex(of: "raw")
        else {
            throw AutoEQError.malformedData
        }
        var f: [Double] = []
        var r: [Double] = []
        for line in lines.dropFirst() {
            let cells = line.components(separatedBy: ",")
            guard cells.count > max(fi, ri), let x = Double(cells[fi]), let y = Double(cells[ri])
            else {
                throw AutoEQError.malformedData
            }
            f.append(x)
            r.append(y)
        }
        let curve = Self(frequency: f, raw: r)
        guard curve.isValid else { throw AutoEQError.malformedData }
        return curve
    }
}

/// Bounded coordinate descent and joint least-squares refinement using the audio engine’s RBJ response.
/// This is an approximation, not a port of AutoEq's SciPy optimizer.
enum AutoEQLocalSolver {
    static let version = 3
    static let filterCount = 10
    static let frequencies = (0..<240).map { 20 * pow(1000, Double($0) / 239) }
    private static let smoothingFrequencies: [Double] = {
        let count = Int(ceil(log(20_000.0 / 20) / log(1.01))) + 1
        return (0..<count).map { 20 * pow(1.01, Double($0)) }
    }()

    static func response(
        _ filter: AutoEQEqualizedFilter, at f: Double, sampleRate: Double = 44_100
    ) -> Double {
        let kind: EQFilter.Kind =
            filter.type == "LOW_SHELF"
            ? .lowShelf
            : filter.type == "HIGH_SHELF" ? .highShelf : .bell
        return Biquad(
            kind: kind, frequency: filter.fc, gain: filter.gain, q: filter.q,
            sampleRate: sampleRate
        ).magnitudeDB(at: f, sampleRate: sampleRate)
    }

    /// AutoEq's quadratic Savitzky–Golay smoothing on a uniform log grid.
    /// Uses 1/12-octave and 2-octave windows, sigmoid-blended at 6–8 kHz.
    /// Edge samples evaluate the nearest full-window polynomial (SciPy mode="interp").
    static func smooth(_ curve: AutoEQCurve) throws -> AutoEQCurve {
        guard curve.isValid else { throw AutoEQError.malformedData }
        let grid = smoothingFrequencies
        let values = grid.map { curve.value(at: $0) }
        func filtered(octaves: Double) throws -> [Double] {
            var window = Int((octaves * log(2) / log(1.01)).rounded(.toNearestOrEven))
            if window.isMultiple(of: 2) { window += 1 }
            window = max(3, window)
            let half = window / 2
            let xs = (-half...half).map(Double.init)
            let n = Double(window)
            let s2 = xs.reduce(0) { $0 + $1 * $1 }
            let s4 = xs.reduce(0) { $0 + pow($1, 4) }
            let determinant = n * s4 - s2 * s2
            return try values.indices.map { i in
                try Task.checkCancellation()
                let center = min(values.count - half - 1, max(half, i))
                var y0 = 0.0
                var y1 = 0.0
                var y2 = 0.0
                for j in xs.indices {
                    let y = values[center - half + j]
                    y0 += y
                    y1 += xs[j] * y
                    y2 += xs[j] * xs[j] * y
                }
                let x = Double(i - center)
                return (s4 * y0 - s2 * y2) / determinant
                    + x * y1 / s2 + x * x * (n * y2 - s2 * y0) / determinant
            }
        }
        let normal = try filtered(octaves: 1.0 / 12)
        let treble = try filtered(octaves: 2)
        let center = log(sqrt(6000.0 * 8000))
        let scale = (log(8000.0) - center) / 4
        let smoothed = grid.indices.map { i in
            let weight = 1 / (1 + exp(-(log(grid[i]) - center) / scale))
            return normal[i] * (1 - weight) + treble[i] * weight
        }
        return AutoEQCurve(frequency: grid, raw: smoothed)
    }

    /// Dense combined response, including sub-bass and the high-shelf plateau.
    /// Check common playback rates because RBJ responses depend on sample rate.
    static func peakGain(_ filters: [AutoEQEqualizedFilter]) throws -> Double {
        var peak = 0.0
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000] {
            let biquads = filters.map { filter in
                Biquad(
                    kind: filter.type == "LOW_SHELF"
                        ? .lowShelf
                        : filter.type == "HIGH_SHELF" ? .highShelf : .bell,
                    frequency: filter.fc, gain: filter.gain, q: filter.q, sampleRate: rate)
            }
            for i in 0...4096 {
                if i.isMultiple(of: 256) { try Task.checkCancellation() }
                let f = pow(rate * 0.499, Double(i) / 4096)
                peak = max(peak, biquads.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: rate) })
            }
        }
        return peak
    }

    static func compute(
        measurement: AutoEQCurve, target: AutoEQTarget
    ) throws -> AutoEQEqualizedProfile {
        guard measurement.isValid, let curve = target.fr, curve.isValid else {
            throw AutoEQError.malformedData
        }
        // AutoEq's published batch processing minimizes mean error over 100 Hz–10 kHz.
        // A single point at 1 kHz can bias the entire correction around a local notch.
        let grid = smoothingFrequencies
        let unaligned = grid.map { f -> Double in
            var delta = curve.value(at: f) - measurement.value(at: f)
            if let bass = target.bassBoost {
                delta += response(
                    .init(type: "LOW_SHELF", fc: bass.fc, q: bass.q, gain: bass.gain), at: f)
            }
            return delta
        }
        let alignment = grid.indices.filter { grid[$0] >= 100 && grid[$0] <= 10_000 }
        let offset = alignment.reduce(0) { $0 + unaligned[$1] } / Double(alignment.count)
        let smoothedError = try smooth(.init(frequency: grid, raw: unaligned.map { $0 - offset }))
        // Smoothing attenuates but does not eliminate narrow mid-band nulls; the
        // cap below bounds the desired positive correction at +6 dB. Tapering to
        // zero would discard real broad treble corrections that upstream keeps.
        let desired = frequencies.map { min(6, smoothedError.value(at: $0)) }
        var filters = [
            AutoEQEqualizedFilter(type: "LOW_SHELF", fc: 105, q: 0.7, gain: 0),
            AutoEQEqualizedFilter(type: "HIGH_SHELF", fc: 10000, q: 0.7, gain: 0),
        ]
        filters += (0..<8).map {
            .init(type: "PEAKING", fc: 40 * pow(250, Double($0) / 7), q: 1, gain: 0)
        }
        var responses = filters.map(filterResponse)
        var sum = [Double](repeating: 0, count: frequencies.count)
        for step in [2.0, 1, 0.5, 0.25, 0.125] {
            for _ in 0..<4 {
                for i in filters.indices {
                    try Task.checkCancellation()
                    let residual = zip(sum, responses[i]).map(-)
                    func loss(_ values: [Double]) -> Double {
                        zip(zip(residual, values), desired).reduce(0) {
                            $0 + pow($1.0.0 + $1.0.1 - $1.1, 2)
                        }
                    }
                    var best = loss(responses[i])
                    var chosen = filters[i]
                    var chosenResponse = responses[i]
                    for parameter in 0..<3 {
                        // Keep shelves monotonic; their Q is fixed at 0.7.
                        if parameter != 0 && filters[i].type != "PEAKING" { continue }
                        for direction in [-1.0, 1.0] {
                            var candidate = filters[i]
                            switch parameter {
                            case 0:
                                candidate.gain = min(
                                    12, max(-12, candidate.gain + direction * step))
                            case 1:
                                candidate.fc = min(
                                    10000, max(20, candidate.fc * pow(2, direction * step / 4)))
                            default:
                                candidate.q = min(
                                    10, max(0.1, candidate.q * pow(2, direction * step / 4)))
                            }
                            let values = filterResponse(candidate)
                            let score = loss(values)
                            if score < best {
                                best = score
                                chosen = candidate
                                chosenResponse = values
                            }
                        }
                    }
                    filters[i] = chosen
                    responses[i] = chosenResponse
                    sum = zip(residual, chosenResponse).map(+)
                }
            }
        }
        filters = try refine(filters, desired: desired)
        return try finalizedProfile(filters)
    }

    private static func filterResponse(_ filter: AutoEQEqualizedFilter) -> [Double] {
        let kind: EQFilter.Kind =
            filter.type == "LOW_SHELF"
            ? .lowShelf
            : filter.type == "HIGH_SHELF" ? .highShelf : .bell
        let biquad = Biquad(
            kind: kind, frequency: filter.fc, gain: filter.gain,
            q: filter.q, sampleRate: 44_100)
        return frequencies.map { biquad.magnitudeDB(at: $0, sampleRate: 44_100) }
    }

    /// Damped least squares refines the whole chain together. Joint moves allow
    /// overlapping filters to cooperate where one-at-a-time descent stalls.
    private static func refine(
        _ initial: [AutoEQEqualizedFilter], desired: [Double]
    ) throws -> [AutoEQEqualizedFilter] {
        let parameters = initial.indices.flatMap { i in
            (initial[i].type == "PEAKING" ? [0, 1, 2] : [0]).map { (i, $0) }
        }
        func adjusted(
            _ filter: AutoEQEqualizedFilter, parameter: Int, delta: Double,
            bounded: Bool = true
        ) -> AutoEQEqualizedFilter {
            var candidate = filter
            switch parameter {
            case 0:
                candidate.gain += delta
                if bounded { candidate.gain = min(12, max(-12, candidate.gain)) }
            case 1:
                candidate.fc *= exp(delta)
                if bounded { candidate.fc = min(10_000, max(20, candidate.fc)) }
            default:
                candidate.q *= exp(delta)
                if bounded { candidate.q = min(10, max(0.1, candidate.q)) }
            }
            return candidate
        }
        func combined(_ filters: [AutoEQEqualizedFilter]) -> [Double] {
            filters.map(filterResponse).reduce([Double](repeating: 0, count: frequencies.count)) {
                zip($0, $1).map(+)
            }
        }
        func loss(_ values: [Double]) -> Double {
            zip(values, desired).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
        }
        var filters = initial
        var values = combined(filters)
        var score = loss(values)
        var damping = 0.01
        let count = parameters.count
        for _ in 0..<100 {
            try Task.checkCancellation()
            let residual = zip(desired, values).map(-)
            let jacobian = try parameters.map { i, parameter -> [Double] in
                try Task.checkCancellation()
                let epsilon = 0.001
                let above = filterResponse(
                    adjusted(
                        filters[i], parameter: parameter,
                        delta: epsilon, bounded: false))
                let below = filterResponse(
                    adjusted(
                        filters[i], parameter: parameter,
                        delta: -epsilon, bounded: false))
                return zip(above, below).map { ($0 - $1) / (2 * epsilon) }
            }
            var matrix = [[Double]](
                repeating: [Double](repeating: 0, count: count + 1), count: count)
            for i in 0..<count {
                for j in 0...i {
                    let dot = zip(jacobian[i], jacobian[j]).reduce(0) { $0 + $1.0 * $1.1 }
                    matrix[i][j] = dot
                    matrix[j][i] = dot
                }
                matrix[i][i] += damping * max(1e-6, matrix[i][i])
                matrix[i][count] = zip(jacobian[i], residual).reduce(0) { $0 + $1.0 * $1.1 }
            }
            // Pivoted Gaussian elimination of the small normal-equation system.
            var singular = false
            for i in 0..<count {
                let pivot = (i..<count).max { abs(matrix[$0][i]) < abs(matrix[$1][i]) }!
                if abs(matrix[pivot][i]) < 1e-12 {
                    singular = true
                    break
                }
                matrix.swapAt(i, pivot)
                let divisor = matrix[i][i]
                for j in i...count { matrix[i][j] /= divisor }
                for row in (i + 1)..<count {
                    let factor = matrix[row][i]
                    for j in i...count { matrix[row][j] -= factor * matrix[i][j] }
                }
            }
            if singular {
                damping *= 10
                continue
            }
            var delta = [Double](repeating: 0, count: count)
            for i in (0..<count).reversed() {
                delta[i] = matrix[i][count]
                for j in (i + 1)..<count { delta[i] -= matrix[i][j] * delta[j] }
            }
            var candidate = filters
            for (j, entry) in parameters.enumerated() {
                let (i, parameter) = entry
                // Bound each proposal as well as the final parameter values.
                let limit = parameter == 0 ? 3.0 : 0.5
                candidate[i] = adjusted(
                    candidate[i], parameter: parameter,
                    delta: min(limit, max(-limit, delta[j])))
            }
            let candidateValues = combined(candidate)
            let candidateScore = loss(candidateValues)
            if candidateScore.isFinite && candidateScore < score {
                let improvement = score - candidateScore
                filters = candidate
                values = candidateValues
                score = candidateScore
                damping = max(1e-8, damping * 0.3)
                if improvement < 1e-6 { break }
            } else {
                damping *= 10
                if damping > 1e12 { break }
            }
        }
        return filters
    }

    /// Quantize the fitted filters and derive playable headroom independently of fitting.
    static func finalizedProfile(_ fitted: [AutoEQEqualizedFilter]) throws -> AutoEQEqualizedProfile
    {
        var filters = fitted
        // Match import precision before measuring combined headroom.
        for i in filters.indices {
            filters[i].gain = (filters[i].gain * 10).rounded() / 10
            filters[i].fc = filters[i].fc.rounded()
            filters[i].q = (filters[i].q * 100).rounded() / 100
        }
        let peak = try peakGain(filters)
        // CoreEQ can store only -12 dB preamp. Remove excess response gain
        // after fitting, without constraining the optimizer's individual moves.
        // Scaling all gains preserves polarity and remains within filter bounds.
        let fittedGains = filters.map(\.gain)
        var scale = 1.0
        var finalPeak = peak
        while finalPeak > 11.8 {
            try Task.checkCancellation()
            scale *= 0.95
            for i in filters.indices {
                filters[i].gain = (fittedGains[i] * scale * 10).rounded() / 10
            }
            finalPeak = try peakGain(filters)
        }
        let preamp = -ceil((finalPeak + 0.2) * 10) / 10
        return .init(filters: filters, preamp: preamp)
    }
}
