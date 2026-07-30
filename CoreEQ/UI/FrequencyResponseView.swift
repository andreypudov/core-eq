import SwiftUI

/// Composite frequency response of the current EQ bands, drawn on a
/// frequency / dB grid. The x-axis is band-aligned: each band's center sits
/// exactly above its slider column in the main window, with logarithmic
/// interpolation between bands.
///
/// The magnitude math comes from `PeakingFilter`, the same type `EQProcessor`
/// renders with, so the curve shows what the audio path actually does at the
/// engine's sample rate (for example, the 20 kHz band flattens out when the
/// output device runs at 44.1 kHz).
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

    /// Draws the plot's own rounded backdrop. Turned off in the main window,
    /// where the enclosing section card already supplies the surface.
    var showsBackground = true

    @State private var draggedBandIndex: Int?
    @State private var hoveredBandIndex: Int?

    /// Display range. Slightly wider than the ±12 dB slider range because
    /// overlapping bands can sum a few dB past a single band's maximum.
    private static let maxDB = 14.0
    private static let curvePointCount = 160
    private static let handleHitRadius: CGFloat = 14

    /// Only the extremes and the reference are marked. The ±6 dB rules were
    /// noise: the curve is read against 0 dB, and the frequency divisions
    /// already carry the grid.
    private static let labeledDBs: [Double] = [12, 0, -12]

    /// Width reserved at the left for the dB labels, so they sit outside the
    /// plot rather than over the curve. The main window insets its band sliders
    /// by the same amount to keep the two aligned; the minimal menu-bar graph
    /// has no labels and so no gutter.
    private var axisGutter: CGFloat { minimal ? 0 : Theme.axisGutter }

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
                    drawBandCurve(context, size)
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
                .fill(.quaternary.opacity(showsBackground ? (minimal ? 0.35 : 0.5) : 0))
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
        for index in bands.indices {
            let distance = hypot(
                location.x - handleCenter(at: index, size).x,
                location.y - handleCenter(at: index, size).y
            )
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
        // Inverse of `yPosition`, so a dragged handle tracks the pointer exactly.
        let dB = Self.maxDB * (1.0 - 2.0 * Double(y / plotHeight(size)))
        let range = BuiltInProfiles.gainRange
        let clamped = min(max(dB, range.lowerBound), range.upperBound)
        return (clamped * 2).rounded() / 2
    }

    /// Where a band's handle sits: at the band's own gain.
    ///
    /// Deliberately *not* on the composite curve. The handle is the filter — its
    /// height is the parameter being edited, so it matches the band's slider and
    /// its readout exactly, and moving one band never shifts another band's
    /// handle. Because the bands overlap by an octave the summed curve rides
    /// above the handles, which `drawBandCurve` explains by drawing the
    /// highlighted band's own bell underneath it.
    private func handleCenter(at index: Int, _ size: CGSize) -> CGPoint {
        CGPoint(
            x: xPosition(bands[index].frequency, size),
            y: yPosition(bands[index].gain, size)
        )
    }

    // MARK: - Drawing

    /// Live analyzer spectrum, drawn as a filled backdrop on the same
    /// band-aligned x-axis as the curve so peaks line up with the bands. It
    /// uses its own vertical scale (0...1 over the full height), independent of
    /// the ±dB gain axis, since it represents signal level rather than gain.
    private func drawSpectrum(_ context: GraphicsContext, _ size: CGSize) {
        // Silence would otherwise stroke a flat line along the floor of the
        // plot, which reads as a stray rule under the frequency labels.
        guard spectrum.count > 1, spectrum.contains(where: { $0.level > 0.02 }) else { return }

        let bottom = plotHeight(size)
        var line = Path()
        for (index, point) in spectrum.enumerated() {
            let x = xPosition(point.frequency, size)
            let y = bottom * (1 - CGFloat(point.level))
            if index == 0 {
                line.move(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
            }
        }

        var fill = line
        fill.addLine(to: CGPoint(x: xPosition(spectrum[spectrum.count - 1].frequency, size), y: bottom))
        fill.addLine(to: CGPoint(x: xPosition(spectrum[0].frequency, size), y: bottom))
        fill.closeSubpath()

        // Deliberately faint: the analyzer is context for the curve, not a
        // second subject.
        context.fill(fill, with: .color(.primary.opacity(0.05)))
        context.stroke(line, with: .color(.primary.opacity(0.13)), lineWidth: 1)
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
        let bottom = plotHeight(size)
        let left = axisGutter

        // Dotted verticals on the band centers are the whole grid — the major
        // frequency divisions, and nothing else competing with the curve.
        var verticals = Path()
        for frequency in anchors {
            let x = xPosition(frequency, size)
            verticals.move(to: CGPoint(x: x, y: 0))
            verticals.addLine(to: CGPoint(x: x, y: bottom))
        }
        context.stroke(
            verticals,
            with: .color(.primary.opacity(0.09)),
            style: StrokeStyle(lineWidth: 1, dash: [2, 4])
        )

        // The single reference the curve is actually read against.
        var zeroLine = Path()
        let zeroY = yPosition(0, size)
        zeroLine.move(to: CGPoint(x: left, y: zeroY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
        context.stroke(zeroLine, with: .color(.primary.opacity(0.14)), lineWidth: 1)

        for frequency in anchors {
            let label = Text(BandFormat.frequency(frequency))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: xPosition(frequency, size), y: bottom + labelStripHeight / 2), anchor: .center)
        }
        // Lighter than the frequency labels: the dB scale should never pull the
        // eye off the curve.
        for dB in Self.labeledDBs {
            let label = Text(BandFormat.axisGain(dB))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            context.draw(label, at: CGPoint(x: left - 8, y: yPosition(dB, size)), anchor: .trailing)
        }
    }

    /// The highlighted band's own filter, on its own, under the composite.
    ///
    /// This is what makes the handles legible. The bands overlap by an octave,
    /// so the summed curve sits above any single band's gain and the handles
    /// appear to float off it. Showing the one bell the handle belongs to —
    /// peaking exactly at the handle — makes it plain that the bold line is the
    /// sum of eleven of these, not the thing being dragged.
    private func drawBandCurve(_ context: GraphicsContext, _ size: CGSize) {
        guard let index = draggedBandIndex ?? hoveredBandIndex, bands.indices.contains(index) else { return }
        let filter = PeakingFilter(band: bands[index], sampleRate: sampleRate)

        var bell = Path()
        for step in 0..<Self.curvePointCount {
            let fraction = Double(step) / Double(Self.curvePointCount - 1)
            let dB = filter.magnitudeDB(at: frequency(atFraction: fraction), sampleRate: sampleRate)
            let point = CGPoint(x: axisGutter + CGFloat(fraction) * plotWidth(size), y: yPosition(dB, size))
            if step == 0 {
                bell.move(to: point)
            } else {
                bell.addLine(to: point)
            }
        }

        context.stroke(
            bell,
            with: .color(.coreEQAccent.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1, lineJoin: .round, dash: [3, 3])
        )
    }

    private func drawCurve(_ context: GraphicsContext, _ size: CGSize) {
        let points = responsePoints(size)
        guard points.count > 1 else { return }

        var curve = Path()
        curve.move(to: points[0])
        curve.addLines(Array(points.dropFirst()))

        // Fill the area under the curve down to the floor of the plot — a flat
        // wash rather than a gradient, so it reads as a tint and not as a
        // second graphic competing with the line.
        let floor = plotHeight(size)
        var fill = curve
        fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: floor))
        fill.addLine(to: CGPoint(x: points[0].x, y: floor))
        fill.closeSubpath()
        // A gentle fade rather than a flat wash: at a constant opacity the fill
        // reads as a solid green block, because a boosted curve sits above zero
        // across the whole range and the area under it is most of the plot.
        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [.coreEQAccent.opacity(0.20), .coreEQAccent.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: floor)
            )
        )

        context.stroke(curve, with: .color(.coreEQAccent), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }

    private func drawBandMarkers(_ context: GraphicsContext, _ size: CGSize) {
        let highlightedIndex = draggedBandIndex ?? hoveredBandIndex
        for (index, band) in bands.enumerated() {
            // Bands the processor turns into identity filters (at or above
            // Nyquist for the current sample rate) are shown dimmed.
            let isActive = PeakingFilter.isActive(
                frequency: band.frequency, gain: band.gain, sampleRate: sampleRate
            ) || band.gain == 0
            let center = handleCenter(at: index, size)
            let radius: CGFloat = index == highlightedIndex ? 6 : 5
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

            // Logic Pro's handle: a white core inside an accent ring, which
            // stays legible over both the fill and the grid.
            context.fill(dot, with: .color(.white.opacity(isActive ? 0.95 : 0.35)))
            context.stroke(
                dot,
                with: .color(.coreEQAccent.opacity(isActive ? 1.0 : 0.35)),
                lineWidth: index == highlightedIndex ? 2.5 : 2
            )
        }

        // Gain readout above the handle while dragging.
        if let index = draggedBandIndex, bands.indices.contains(index) {
            let band = bands[index]
            let center = handleCenter(at: index, size)
            let label = Text(BandFormat.gain(band.gain))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
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
        let filters = bands.map { PeakingFilter(band: $0, sampleRate: sampleRate) }

        return (0..<Self.curvePointCount).map { index in
            let fraction = Double(index) / Double(Self.curvePointCount - 1)
            let frequency = frequency(atFraction: fraction)
            let dB = filters.reduce(0.0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
            return CGPoint(x: axisGutter + CGFloat(fraction) * plotWidth(size), y: yPosition(dB, size))
        }
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

    /// Horizontal extent of the plot, to the right of the dB-label gutter.
    private func plotWidth(_ size: CGSize) -> CGFloat {
        max(size.width - axisGutter, 1)
    }

    private func xPosition(_ frequency: Double, _ size: CGSize) -> CGFloat {
        axisGutter + CGFloat(min(max(axisFraction(of: frequency), 0), 1)) * plotWidth(size)
    }

    /// The minimal menu graph reserves only half the stroke width at the top and
    /// bottom, so at extreme settings the curve reaches the edges of the compact
    /// box and clamps there — filling the space without the line bleeding past
    /// the border. The full window keeps its original edge-to-edge mapping.
    private var verticalInset: CGFloat { minimal ? 1 : 0 }

    /// Strip along the bottom holding the frequency labels. Keeping it outside
    /// the dB scale stops the lowest gridline label from landing on top of the
    /// first band's label in the corner.
    private var labelStripHeight: CGFloat { minimal ? 0 : 17 }

    /// Vertical extent of the dB scale, above the frequency-label strip.
    private func plotHeight(_ size: CGSize) -> CGFloat {
        max(size.height - labelStripHeight, 1)
    }

    private func yPosition(_ dB: Double, _ size: CGSize) -> CGFloat {
        let clamped = min(max(dB, -Self.maxDB), Self.maxDB)
        let half = plotHeight(size) / 2
        let usable = half - verticalInset
        return half - usable * CGFloat(clamped / Self.maxDB)
    }

}
