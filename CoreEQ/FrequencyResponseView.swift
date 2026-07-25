import SwiftUI

/// Composite frequency response of the current EQ bands, drawn on a
/// frequency / dB grid. The x-axis is band-aligned: each band's center sits
/// exactly above its slider column in the main window, with logarithmic
/// interpolation between bands.
///
/// The magnitude math mirrors `EQProcessor` exactly — the same RBJ
/// peaking-filter coefficients and the same Nyquist / negligible-gain guards —
/// so the curve shows what the render path actually does at the engine's
/// sample rate (for example, the 20 kHz band flattens out when the output
/// device runs at 44.1 kHz).
///
/// The band dots are interactive handles: dragging one vertically adjusts the
/// band's gain (snapped to the same 0.5 dB step as the sliders), and a
/// double-click resets the band to the active profile's original value.
/// Frequencies are fixed by design, so dragging is vertical-only.
struct FrequencyResponseView: View {
    let bands: [EQBand]
    let sampleRate: Double
    /// Log-spaced spectrum points (ascending frequency, level 0...1) drawn as a
    /// backdrop behind the grid and curve. Empty hides the backdrop.
    var spectrum: [SpectrumAnalyzer.Point] = []
    var onGainChange: ((_ bandIndex: Int, _ gain: Double) -> Void)?
    var onBandReset: ((_ bandIndex: Int) -> Void)?

    /// Compact, read-only presentation for the menu-bar Quick EQ: no grid,
    /// labels, band handles, or interaction — just the smooth curve, resembling
    /// Apple's EQ preview. Defaults to the full interactive plot.
    var minimal = false

    @State private var draggedBandIndex: Int?
    @State private var hoveredBandIndex: Int?

    /// Display range. Slightly wider than the ±12 dB slider range because
    /// overlapping bands can sum a few dB past a single band's maximum.
    private static let maxDB = 14.0
    private static let curvePointCount = 160
    private static let handleHitRadius: CGFloat = 14

    private static let gridDBs: [Double] = [-12, -6, 6, 12]

    /// Band center frequencies, ascending — the anchors of the x-axis.
    private var anchors: [Double] { bands.map(\.frequency).sorted() }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if minimal {
                Canvas { context, _ in
                    drawBaseline(context, size)
                    drawCurve(context, size)
                }
            } else {
                Canvas { context, _ in
                    drawSpectrum(context, size)
                    drawGrid(context, size)
                    drawCurve(context, size)
                    drawBandMarkers(context, size)
                }
                .gesture(dragGesture(size))
                .simultaneousGesture(doubleClickGesture(size))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredBandIndex = bandIndex(near: location, size)
                    case .ended:
                        hoveredBandIndex = nil
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(minimal ? 0.35 : 0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Equalizer frequency response curve")
        .accessibilityHidden(minimal)
    }

    // MARK: - Interaction

    private func dragGesture(_ size: CGSize) -> some Gesture {
        // The 3 pt minimum distance keeps clicks (including the first click
        // of a double-click) from grabbing a handle and jittering its gain.
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard let index = draggedBandIndex ?? bandIndex(near: value.startLocation, size) else { return }
                draggedBandIndex = index
                onGainChange?(index, snappedGain(atY: value.location.y, size))
            }
            .onEnded { _ in
                draggedBandIndex = nil
            }
    }

    private func doubleClickGesture(_ size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                if let index = bandIndex(near: value.location, size) {
                    onBandReset?(index)
                }
            }
    }

    /// The band whose handle is within grabbing distance of `location`,
    /// preferring the nearest when handles are close together.
    private func bandIndex(near location: CGPoint, _ size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, band) in bands.enumerated() {
            let center = CGPoint(x: xPosition(band.frequency, size), y: yPosition(band.gain, size))
            let distance = hypot(location.x - center.x, location.y - center.y)
            if distance <= Self.handleHitRadius, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Gain for a handle dragged to vertical position `y`, clamped to the
    /// slider range and snapped to the sliders' 0.5 dB step so the curve and
    /// the sliders always agree.
    private func snappedGain(atY y: CGFloat, _ size: CGSize) -> Double {
        let dB = Self.maxDB * (1.0 - 2.0 * Double(y / max(size.height, 1)))
        let range = BuiltInProfiles.gainRange
        let clamped = min(max(dB, range.lowerBound), range.upperBound)
        return (clamped * 2).rounded() / 2
    }

    // MARK: - Drawing

    /// Live analyzer spectrum, drawn as a filled backdrop on the same
    /// band-aligned x-axis as the curve so peaks line up with the bands. It
    /// uses its own vertical scale (0...1 over the full height), independent of
    /// the ±dB gain axis, since it represents signal level rather than gain.
    private func drawSpectrum(_ context: GraphicsContext, _ size: CGSize) {
        guard spectrum.count > 1 else { return }

        var line = Path()
        for (index, point) in spectrum.enumerated() {
            let x = xPosition(point.frequency, size)
            let y = size.height * (1 - CGFloat(point.level))
            if index == 0 {
                line.move(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
            }
        }

        var fill = line
        fill.addLine(to: CGPoint(x: xPosition(spectrum[spectrum.count - 1].frequency, size), y: size.height))
        fill.addLine(to: CGPoint(x: xPosition(spectrum[0].frequency, size), y: size.height))
        fill.closeSubpath()

        context.fill(fill, with: .color(.primary.opacity(0.09)))
        context.stroke(line, with: .color(.primary.opacity(0.22)), lineWidth: 1)
    }

    /// Single faint 0 dB reference line for the minimal presentation, so the
    /// curve reads as a deviation from flat without a full grid.
    private func drawBaseline(_ context: GraphicsContext, _ size: CGSize) {
        var line = Path()
        let y = yPosition(0, size)
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(line, with: .color(.primary.opacity(0.12)), lineWidth: 1)
    }

    private func drawGrid(_ context: GraphicsContext, _ size: CGSize) {
        var lines = Path()
        for frequency in anchors {
            let x = xPosition(frequency, size)
            lines.move(to: CGPoint(x: x, y: 0))
            lines.addLine(to: CGPoint(x: x, y: size.height))
        }
        for dB in Self.gridDBs {
            let y = yPosition(dB, size)
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(lines, with: .color(.primary.opacity(0.07)), lineWidth: 1)

        // Emphasized 0 dB line.
        var zeroLine = Path()
        let zeroY = yPosition(0, size)
        zeroLine.move(to: CGPoint(x: 0, y: zeroY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
        context.stroke(zeroLine, with: .color(.primary.opacity(0.2)), lineWidth: 1)

        for frequency in anchors {
            let label = Text(frequencyLabel(frequency))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: xPosition(frequency, size), y: size.height - 3), anchor: .bottom)
        }
        for dB in Self.gridDBs {
            let label = Text(String(format: "%+.0f", dB))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: 4, y: yPosition(dB, size)), anchor: .leading)
        }
    }

    private func drawCurve(_ context: GraphicsContext, _ size: CGSize) {
        let points = responsePoints(size)
        guard points.count > 1 else { return }

        var curve = Path()
        curve.move(to: points[0])
        curve.addLines(Array(points.dropFirst()))

        // Fill the area between the curve and the 0 dB line.
        let zeroY = yPosition(0, size)
        var fill = curve
        fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: zeroY))
        fill.addLine(to: CGPoint(x: points[0].x, y: zeroY))
        fill.closeSubpath()
        context.fill(fill, with: .color(.accentColor.opacity(0.15)))

        context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }

    private func drawBandMarkers(_ context: GraphicsContext, _ size: CGSize) {
        let highlightedIndex = draggedBandIndex ?? hoveredBandIndex
        for (index, band) in bands.enumerated() {
            // Bands the processor turns into identity filters (at or above
            // Nyquist for the current sample rate) are shown dimmed.
            let isActive = band.frequency < sampleRate * 0.47
            let center = CGPoint(x: xPosition(band.frequency, size), y: yPosition(band.gain, size))
            let radius: CGFloat = index == highlightedIndex ? 5.5 : 3.5
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(.accentColor.opacity(isActive ? 1.0 : 0.35)))
            if index == highlightedIndex {
                context.stroke(dot, with: .color(.primary.opacity(0.4)), lineWidth: 1)
            }
        }

        // Gain readout above the handle while dragging.
        if let index = draggedBandIndex, bands.indices.contains(index) {
            let band = bands[index]
            let center = CGPoint(x: xPosition(band.frequency, size), y: yPosition(band.gain, size))
            let label = Text(String(format: "%+.1f dB", band.gain))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
            let position = CGPoint(
                x: min(max(center.x, 26), size.width - 26),
                y: max(center.y - 12, 14)
            )
            context.draw(label, at: position, anchor: .bottom)
        }
    }

    // MARK: - Response math (mirrors EQProcessor)

    private func responsePoints(_ size: CGSize) -> [CGPoint] {
        let coefficients = bands.compactMap { peakingCoefficients(for: $0) }

        return (0..<Self.curvePointCount).map { index in
            let fraction = Double(index) / Double(Self.curvePointCount - 1)
            let frequency = frequency(atFraction: fraction)
            let dB = coefficients.reduce(0.0) { $0 + magnitudeDB($1, at: frequency) }
            return CGPoint(x: fraction * size.width, y: yPosition(dB, size))
        }
    }

    private struct BiquadCoefficients {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    }

    /// RBJ peaking-filter coefficients, with the same guards as
    /// `EQProcessor.computeCoefficients`; nil means the band is an identity
    /// filter and contributes nothing to the curve.
    private func peakingCoefficients(for band: EQBand) -> BiquadCoefficients? {
        guard band.frequency > 10, band.frequency < sampleRate * 0.47, abs(band.gain) > 0.001 else {
            return nil
        }
        let amp = pow(10.0, band.gain / 40.0)
        let w0 = 2.0 * Double.pi * band.frequency / sampleRate
        let alpha = sin(w0) / (2.0 * max(band.q, 0.05))
        let cosw0 = cos(w0)
        let a0 = 1.0 + alpha / amp
        return BiquadCoefficients(
            b0: (1.0 + alpha * amp) / a0,
            b1: (-2.0 * cosw0) / a0,
            b2: (1.0 - alpha * amp) / a0,
            a1: (-2.0 * cosw0) / a0,
            a2: (1.0 - alpha / amp) / a0
        )
    }

    /// Magnitude of H(e^jw) in dB for one biquad at the given frequency.
    private func magnitudeDB(_ c: BiquadCoefficients, at frequency: Double) -> Double {
        let w = 2.0 * Double.pi * frequency / sampleRate
        let cosw = cos(w), sinw = sin(w)
        let cos2w = cos(2 * w), sin2w = sin(2 * w)
        let numeratorReal = c.b0 + c.b1 * cosw + c.b2 * cos2w
        let numeratorImag = -(c.b1 * sinw + c.b2 * sin2w)
        let denominatorReal = 1.0 + c.a1 * cosw + c.a2 * cos2w
        let denominatorImag = -(c.a1 * sinw + c.a2 * sin2w)
        let numerator = numeratorReal * numeratorReal + numeratorImag * numeratorImag
        let denominator = denominatorReal * denominatorReal + denominatorImag * denominatorImag
        guard denominator > 0 else { return 0 }
        return 10.0 * log10(numerator / denominator)
    }

    // MARK: - Coordinate mapping

    /// X-axis aligned with the slider columns underneath the plot: band `i`
    /// sits at fraction `(i + 0.5) / bandCount`, and frequencies between
    /// bands interpolate logarithmically. Beyond the outermost bands the axis
    /// extrapolates using the neighboring octave ratio.
    private func axisFraction(of frequency: Double) -> Double {
        let anchors = self.anchors
        let n = anchors.count
        guard n >= 2, frequency > 0 else { return 0.5 }
        let slot = 1.0 / Double(n)
        func center(_ i: Int) -> Double { (Double(i) + 0.5) * slot }

        if frequency <= anchors[0] {
            let ratio = anchors[1] / anchors[0]
            return center(0) + slot * log(frequency / anchors[0]) / log(ratio)
        }
        if frequency >= anchors[n - 1] {
            let ratio = anchors[n - 1] / anchors[n - 2]
            return center(n - 1) + slot * log(frequency / anchors[n - 1]) / log(ratio)
        }
        for i in 0..<(n - 1) where frequency <= anchors[i + 1] {
            return center(i) + slot * log(frequency / anchors[i]) / log(anchors[i + 1] / anchors[i])
        }
        return 1
    }

    /// Inverse of `axisFraction`, used to sweep the curve.
    private func frequency(atFraction t: Double) -> Double {
        let anchors = self.anchors
        let n = anchors.count
        guard n >= 2 else { return 1_000 }
        // Position in band-index units, measured from the first band's center.
        let position = t * Double(n) - 0.5

        if position <= 0 {
            return anchors[0] * pow(anchors[1] / anchors[0], position)
        }
        if position >= Double(n - 1) {
            return anchors[n - 1] * pow(anchors[n - 1] / anchors[n - 2], position - Double(n - 1))
        }
        let i = min(Int(position), n - 2)
        return anchors[i] * pow(anchors[i + 1] / anchors[i], position - Double(i))
    }

    private func xPosition(_ frequency: Double, _ size: CGSize) -> CGFloat {
        CGFloat(min(max(axisFraction(of: frequency), 0), 1)) * size.width
    }

    /// The minimal menu graph reserves only half the stroke width at the top and
    /// bottom, so at extreme settings the curve reaches the edges of the compact
    /// box and clamps there — filling the space without the line bleeding past
    /// the border. The full window keeps its original edge-to-edge mapping.
    private var verticalInset: CGFloat { minimal ? 1 : 0 }

    private func yPosition(_ dB: Double, _ size: CGSize) -> CGFloat {
        let clamped = min(max(dB, -Self.maxDB), Self.maxDB)
        let half = size.height / 2
        let usable = half - verticalInset
        return half - usable * CGFloat(clamped / Self.maxDB)
    }

    /// Same label format as the slider columns, so plot and sliders read
    /// identically (e.g. "125", "1k", "15k").
    private func frequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            let kilohertz = frequency / 1_000
            return kilohertz == kilohertz.rounded()
                ? "\(Int(kilohertz))k"
                : String(format: "%.1fk", kilohertz)
        }
        return "\(Int(frequency))"
    }
}
