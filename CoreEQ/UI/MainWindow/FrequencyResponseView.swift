import SwiftUI

/// Composite frequency response of the whole filter chain, drawn on a
/// frequency / dB grid. The x-axis is band-aligned: each ladder band's centre
/// sits exactly above its slider column in the main window, with logarithmic
/// interpolation between bands. Free filters sit wherever their frequency puts
/// them and never move the grid.
///
/// The magnitude math comes from `Biquad`, the same type `EQProcessor` renders
/// with, so the curve shows what the audio path actually does at the engine's
/// sample rate (for example, the 20 kHz band flattens out when the output
/// device runs at 44.1 kHz).
///
/// Two kinds of point sit on the plot, and the difference between them is
/// enforced by the drag rather than explained by a label:
///
/// - *Band handles* are locked to the ladder, so they move vertically only.
/// - *Filter nodes* are free, so they move in both axes.
///
/// Double-click resets a point's gain to 0 dB. With `allowsFilterCreation` set —
/// which the main window ties to the Filters section being open — double-
/// clicking empty space creates a filter there instead, so a user who never
/// opens that section can never make one by accident.
struct FrequencyResponseView: View {
    /// The whole chain: ladder filters and free filters together.
    let filters: [EQFilter]
    let sampleRate: Double

    /// Output trim in dB, applied after the chain. The curve is what you hear,
    /// so it moves with the trim just as the audio does.
    var preamp: Double = 0

    /// Log-spaced spectrum points (ascending frequency, level 0...1) drawn as a
    /// backdrop behind the grid and curve. Empty hides the backdrop.
    var spectrum: [SpectrumAnalyzer.Point] = []

    var onBandGainChange: ((_ slot: Int, _ gain: Double) -> Void)?
    var onBandReset: ((_ slot: Int) -> Void)?
    var onFilterMove: ((_ id: UUID, _ frequency: Double, _ gain: Double) -> Void)?
    var onFilterReset: ((_ id: UUID) -> Void)?
    var onFilterCreate: ((_ frequency: Double, _ gain: Double) -> Void)?

    /// Whether double-clicking empty space creates a filter. Off unless the
    /// user has opened the Filters section.
    var allowsFilterCreation = false

    /// Compact, read-only presentation for the menu-bar Quick EQ: no grid,
    /// labels, handles, or interaction — just the smooth curve, resembling
    /// Apple's EQ preview. Defaults to the full interactive plot.
    var minimal = false

    /// Draws the plot's own rounded backdrop. Turned off in the main window,
    /// where the enclosing section card already supplies the surface.
    var showsBackground = true

    /// Width at the right of the plot that the band ladder does *not* span.
    ///
    /// The main window sets this to the width of the Global Gain column beside
    /// the sliders. The ladder then lays out across exactly the width the slider
    /// strip occupies — so each slider stays under its own point — while the
    /// curve, fill, and spectrum still run to the right edge, with the strip
    /// past 20 kHz carrying the extrapolated top end rather than nothing.
    var bandAxisTrailingInset: CGFloat = 0

    /// A grabbable point on the plot. Bands are addressed by ladder slot and
    /// free filters by identity, so neither can be confused for the other when
    /// the chain changes under a drag.
    private enum Handle: Equatable {
        case band(Int)
        case filter(UUID)
    }

    @State private var dragged: Handle?
    @State private var hovered: Handle?

    /// Display range. Slightly wider than the ±12 dB slider range because
    /// overlapping filters can sum a few dB past a single one's maximum.
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
    /// The plot sits flush with the blocks below it but has no block padding of
    /// its own, so it carries that padding inside its gutter. The band columns
    /// then begin at the same x as the slider columns in the padded block below.
    private var axisGutter: CGFloat { minimal ? 0 : Theme.axisGutter + Theme.blockPadding }

    /// The ladder filters, in slot order.
    private var bands: [EQFilter] {
        filters.filter(\.isBand).sorted { ($0.band ?? 0) < ($1.band ?? 0) }
    }

    private var freeFilters: [EQFilter] {
        filters.filter { !$0.isBand }
    }

    /// Band centre frequencies, ascending — the anchors of the x-axis.
    ///
    /// Deliberately the ladder alone: a free filter must never shift the grid or
    /// the frequency labels, or adding one would move every other point on the
    /// plot sideways.
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
                    drawHighlightedFilterCurve(context, size)
                    drawCurve(context, size)
                    drawBandMarkers(context, size)
                    drawFilterNodes(context, size)
                }
                .gesture(dragGesture(size))
                .simultaneousGesture(doubleClickGesture(size))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hovered = handle(near: location, size)
                    case .ended:
                        hovered = nil
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
                guard let handle = dragged ?? handle(near: value.startLocation, size) else { return }
                dragged = handle
                switch handle {
                case .band(let slot):
                    // Locked to the ladder: vertical only.
                    onBandGainChange?(slot, snappedGain(atY: value.location.y, size))
                case .filter(let id):
                    guard let filter = freeFilters.first(where: { $0.id == id }) else { return }
                    let frequency = frequency(atFraction: fraction(atX: value.location.x, size))
                    // A high or low pass has no gain to drag, so it stays on the
                    // 0 dB line and only its frequency follows the pointer.
                    let gain = filter.kind.usesGain ? snappedGain(atY: value.location.y, size) : filter.gain
                    onFilterMove?(id, frequency, gain)
                }
            }
            .onEnded { _ in
                dragged = nil
            }
    }

    private func doubleClickGesture(_ size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                switch handle(near: value.location, size) {
                case .band(let slot):
                    onBandReset?(slot)
                case .filter(let id):
                    onFilterReset?(id)
                case nil:
                    guard allowsFilterCreation else { return }
                    onFilterCreate?(
                        frequency(atFraction: fraction(atX: value.location.x, size)),
                        snappedGain(atY: value.location.y, size)
                    )
                }
            }
    }

    /// The point within grabbing distance of `location`, preferring the nearest.
    /// Free filters are tested first: they are drawn on top, so they should be
    /// grabbed first where the two overlap.
    private func handle(near location: CGPoint, _ size: CGSize) -> Handle? {
        var best: (handle: Handle, distance: CGFloat)?

        func consider(_ handle: Handle, _ center: CGPoint, bias: CGFloat) {
            let distance = hypot(location.x - center.x, location.y - center.y)
            guard distance <= Self.handleHitRadius else { return }
            if distance - bias < (best?.distance ?? .infinity) {
                best = (handle, distance - bias)
            }
        }

        for filter in freeFilters {
            consider(.filter(filter.id), filterNodeCenter(filter, size), bias: Self.handleHitRadius / 2)
        }
        for (slot, band) in bands.enumerated() {
            consider(.band(slot), bandHandleCenter(band, size), bias: 0)
        }
        return best?.handle
    }

    /// Gain for a point dragged to vertical position `y`, clamped to the slider
    /// range and snapped to the 0.5 dB step used across the app, so the curve
    /// and the numeric readouts always agree.
    private func snappedGain(atY y: CGFloat, _ size: CGSize) -> Double {
        // Inverse of `yPosition`, so a dragged point tracks the pointer exactly.
        let dB = Self.maxDB * (1.0 - 2.0 * Double(y / plotHeight(size)))
        let range = BuiltInProfiles.gainRange
        let clamped = min(max(dB, range.lowerBound), range.upperBound)
        return (clamped * 2).rounded() / 2
    }

    /// Band-region fraction under the pointer, used to turn a drag into a
    /// frequency. Allowed past 1 so a node can be dragged into the strip beyond
    /// the last band, exactly as far as the curve is drawn.
    private func fraction(atX x: CGFloat, _ size: CGSize) -> Double {
        let plot = Double(min(max((x - axisGutter) / plotWidth(size), 0), 1))
        return bandFraction(ofPlotFraction: plot, size)
    }

    /// Where a band's handle sits: at the band's own gain.
    ///
    /// Deliberately *not* on the composite curve. The handle is the filter — its
    /// height is the parameter being edited, so it matches the band's slider and
    /// its readout exactly, and moving one filter never shifts another's handle.
    /// Because the bands overlap by an octave the summed curve rides above the
    /// handles, which `drawHighlightedFilterCurve` explains by drawing the
    /// highlighted filter's own response underneath it.
    private func bandHandleCenter(_ band: EQFilter, _ size: CGSize) -> CGPoint {
        CGPoint(x: xPosition(band.frequency, size), y: yPosition(band.gain, size))
    }

    /// Same rule for a free filter, except that a high or low pass has no gain
    /// and so rides the 0 dB line.
    private func filterNodeCenter(_ filter: EQFilter, _ size: CGSize) -> CGPoint {
        CGPoint(
            x: xPosition(filter.frequency, size),
            y: yPosition(filter.kind.usesGain ? filter.gain : 0, size)
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

    /// The highlighted point's own filter, on its own, under the composite.
    ///
    /// This is what makes the points legible. Filters overlap, so the summed
    /// curve sits above any single one's gain and a handle appears to float off
    /// it. Showing the one response the handle belongs to — peaking exactly at
    /// the handle — makes it plain that the bold line is the sum of the whole
    /// chain, not the thing being dragged.
    private func drawHighlightedFilterCurve(_ context: GraphicsContext, _ size: CGSize) {
        guard let handle = dragged ?? hovered else { return }
        let source: EQFilter?
        switch handle {
        case .band(let slot): source = bands[safe: slot]
        case .filter(let id): source = freeFilters.first { $0.id == id }
        }
        guard let source else { return }
        let biquad = Biquad(filter: source, sampleRate: sampleRate)

        var response = Path()
        for step in 0..<Self.curvePointCount {
            let fraction = Double(step) / Double(Self.curvePointCount - 1)
            let probe = frequency(atFraction: bandFraction(ofPlotFraction: fraction, size))
            let dB = biquad.magnitudeDB(at: probe, sampleRate: sampleRate)
            let point = CGPoint(x: axisGutter + CGFloat(fraction) * plotWidth(size), y: yPosition(dB, size))
            if step == 0 {
                response.move(to: point)
            } else {
                response.addLine(to: point)
            }
        }

        context.stroke(
            response,
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
        for (slot, band) in bands.enumerated() {
            let isHighlighted = (dragged ?? hovered) == .band(slot)
            // Bands the processor turns into identity filters (at or above
            // Nyquist for the current sample rate) are shown dimmed.
            let isActive = band.isEnabled && (Biquad.isActive(
                kind: band.kind, frequency: band.frequency, gain: band.gain, sampleRate: sampleRate
            ) || band.gain == 0)
            let center = bandHandleCenter(band, size)
            let radius: CGFloat = isHighlighted ? 6 : 5
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

            // Logic Pro's handle: a white core inside an accent ring, which
            // stays legible over both the fill and the grid.
            context.fill(dot, with: .color(.white.opacity(isActive ? 0.95 : 0.35)))
            context.stroke(
                dot,
                with: .color(.coreEQAccent.opacity(isActive ? 1.0 : 0.35)),
                lineWidth: isHighlighted ? 2.5 : 2
            )
        }

        if case .band(let slot)? = dragged, let band = bands[safe: slot] {
            drawGainLabel(context, size, center: bandHandleCenter(band, size), gain: band.gain)
        }
    }

    /// Free filters, drawn larger than the band handles and with an outer ring.
    ///
    /// The size difference is the visual half of the same distinction the drag
    /// enforces: these are the points that move in two axes.
    private func drawFilterNodes(_ context: GraphicsContext, _ size: CGSize) {
        for (index, filter) in freeFilters.enumerated() {
            let isHighlighted = (dragged ?? hovered) == .filter(filter.id)
            let isActive = filter.isEnabled && Biquad.isActive(
                kind: filter.kind, frequency: filter.frequency, gain: filter.gain, sampleRate: sampleRate
            )
            let center = filterNodeCenter(filter, size)
            let radius: CGFloat = isHighlighted ? 8 : 7
            let core = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let ring = Path(ellipseIn: CGRect(x: center.x - radius - 3, y: center.y - radius - 3, width: (radius + 3) * 2, height: (radius + 3) * 2))

            context.stroke(ring, with: .color(.coreEQAccent.opacity(isActive ? 0.45 : 0.2)), lineWidth: 1)
            context.fill(core, with: .color(.white.opacity(isActive ? 0.95 : 0.35)))
            context.stroke(
                core,
                with: .color(.coreEQAccent.opacity(isActive ? 1.0 : 0.35)),
                lineWidth: isHighlighted ? 2.5 : 2
            )

            let number = Text("\(index + 1)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.black.opacity(isActive ? 0.7 : 0.3))
            context.draw(number, at: center, anchor: .center)
        }

        if case .filter(let id)? = dragged, let filter = freeFilters.first(where: { $0.id == id }) {
            let center = filterNodeCenter(filter, size)
            let text = filter.kind.usesGain
                ? "\(BandFormat.frequency(filter.frequency)) Hz  \(BandFormat.gain(filter.gain))"
                : "\(BandFormat.frequency(filter.frequency)) Hz"
            drawLabel(context, size, center: center, text: text)
        }
    }

    private func drawGainLabel(_ context: GraphicsContext, _ size: CGSize, center: CGPoint, gain: Double) {
        drawLabel(context, size, center: center, text: BandFormat.gain(gain))
    }

    private func drawLabel(_ context: GraphicsContext, _ size: CGSize, center: CGPoint, text: String) {
        let label = Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.primary)
        let position = CGPoint(
            x: min(max(center.x, 60), size.width - 60),
            y: max(center.y - 14, 14)
        )
        context.draw(label, at: position, anchor: .bottom)
    }

    // MARK: - Response math (mirrors EQProcessor)

    private func responsePoints(_ size: CGSize) -> [CGPoint] {
        let biquads = filters.map { Biquad(filter: $0, sampleRate: sampleRate) }

        return (0..<Self.curvePointCount).map { index in
            let fraction = Double(index) / Double(Self.curvePointCount - 1)
            let frequency = frequency(atFraction: bandFraction(ofPlotFraction: fraction, size))
            let dB = biquads.reduce(preamp) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
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

    /// Inverse of `axisFraction`, used to sweep the curve and to turn a pointer
    /// position into the frequency a dragged filter should take.
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

    /// The part of the plot the band ladder is laid out across.
    private func bandRegionWidth(_ size: CGSize) -> CGFloat {
        max(plotWidth(size) - bandAxisTrailingInset, 1)
    }

    /// Fraction of the *plot* at which a fraction of the *band region* falls.
    /// Positions past the last band land beyond 1, which is what lets the curve
    /// carry on to the right edge.
    private func plotFraction(ofBandFraction t: Double, _ size: CGSize) -> Double {
        t * Double(bandRegionWidth(size) / plotWidth(size))
    }

    private func bandFraction(ofPlotFraction t: Double, _ size: CGSize) -> Double {
        t * Double(plotWidth(size) / bandRegionWidth(size))
    }

    private func xPosition(_ frequency: Double, _ size: CGSize) -> CGFloat {
        let band = min(max(axisFraction(of: frequency), 0), 1)
        return axisGutter + CGFloat(plotFraction(ofBandFraction: band, size)) * plotWidth(size)
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
