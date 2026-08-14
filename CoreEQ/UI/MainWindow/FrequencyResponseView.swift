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
/// Clicking a filter node selects it, which is the same selection the
/// parametric table's rows carry: one band, pointed at from either side.
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

    /// The analyzer whose output is drawn behind the grid and curve, or nil for
    /// no backdrop. Deliberately the object rather than its points: it is
    /// observed by `SpectrumBackdrop` alone, so its sixty-a-second updates
    /// invalidate that layer and leave this view untouched.
    var spectrum: SpectrumAnalyzer?

    /// The filter whose node is drawn as chosen, and whose row is highlighted in
    /// the parametric table. One selection, shown in both places.
    var selectedFilterID: UUID?

    /// The band the pointer is on down in the slider strip, and the one being
    /// dragged there.
    ///
    /// A slider and a handle on this curve are two grips on the same band, so
    /// moving either one is answered here: the handle lights up, and while the
    /// band is actually moving its value is drawn beside it — in the one place
    /// that can show what the change did to the sound.
    var stripHoveredBand: Int?
    var stripDraggedBand: Int?

    var onBandGainChange: ((_ slot: Int, _ gain: Double) -> Void)?
    var onBandReset: ((_ slot: Int) -> Void)?
    var onFilterMove: ((_ id: UUID, _ frequency: Double, _ gain: Double) -> Void)?
    var onFilterReset: ((_ id: UUID) -> Void)?
    var onFilterCreate: ((_ frequency: Double, _ gain: Double) -> Void)?
    /// A click landed on a filter node, or on nothing. Nil clears the
    /// selection, so clicking the empty plot puts the table back to no row
    /// chosen rather than leaving a stale one behind.
    var onFilterSelect: ((_ id: UUID?) -> Void)?

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

    /// A grabbable point on the plot. Bands are addressed by ladder slot and
    /// free filters by identity, so neither can be confused for the other when
    /// the chain changes under a drag.
    private enum Handle: Equatable {
        case band(Int)
        case filter(UUID)
    }

    @State private var dragged: Handle?
    @State private var hovered: Handle?

    /// The point being moved, from either grip.
    private var activeDrag: Handle? {
        dragged ?? stripDraggedBand.map(Handle.band)
    }

    /// The point being pointed at, from either grip.
    private var activeHover: Handle? {
        hovered ?? stripHoveredBand.map(Handle.band)
    }

    /// Display range. Slightly wider than the ±12 dB slider range because
    /// overlapping filters can sum a few dB past a single one's maximum.
    private static let maxDB = 14.0
    private static let curvePointCount = 160
    /// Grabbing distance, a little wider than the largest node so a click just
    /// off one still lands on it.
    private static let handleHitRadius: CGFloat = 16

    /// Only the extremes and the reference are marked. The ±6 dB rules were
    /// noise: the curve is read against 0 dB, and the frequency divisions
    /// already carry the grid.
    private static let labeledDBs: [Double] = [12, 0, -12]

    /// Width reserved at the left for the dB labels, so they sit outside the
    /// plot rather than over the curve. The main window insets its band sliders
    /// by the same amount to keep the two aligned; the minimal menu-bar graph
    /// has no labels and so no gutter.
    private var axisGutter: CGFloat { minimal ? 0 : Theme.axisGutter }

    /// The ladder filters, in slot order.
    private var bands: [EQFilter] {
        filters.filter(\.isBand).sorted { ($0.band ?? 0) < ($1.band ?? 0) }
    }

    private var freeFilters: [EQFilter] {
        filters.filter { !$0.isBand }
    }

    /// Band centre frequencies, ascending — the anchors of the x-axis.
    ///
    /// The ladder itself rather than the chain's band filters, which are always
    /// the same values: `ProfileManager.normalized` guarantees one filter per
    /// slot carrying that slot's frequency. Deriving it instead cost a `filter`
    /// and a `sorted` *per call*, and this is called once per curve point, once
    /// per spectrum point, and once per handle — several hundred times a frame,
    /// sixty times a second.
    ///
    /// Deliberately the ladder alone: a free filter must never shift the grid or
    /// the frequency labels, or adding one would move every other point on the
    /// plot sideways.
    private var anchors: [Double] { BuiltInProfiles.frequencies }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if minimal {
                Canvas { context, _ in
                    drawBaseline(context, size)
                    drawCurve(context, size)
                }
            } else {
                ZStack {
                    if let spectrum {
                        SpectrumBackdrop(
                            spectrum: spectrum,
                            axis: axis(size),
                            plotHeight: plotHeight(size)
                        )
                    }

                    Canvas { context, _ in
                        drawGrid(context, size)
                        drawHighlightedFilterCurve(context, size)
                        drawCurve(context, size)
                        drawBandMarkers(context, size)
                        drawFilterNodes(context, size)
                    }
                }
                .gesture(dragGesture(size))
                .simultaneousGesture(doubleClickGesture(size))
                .simultaneousGesture(selectionGesture(size))
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

    /// A plain click chooses the point it lands on, which is what puts the
    /// matching row in the parametric table into selection — and, coming the
    /// other way, a row chosen there is what draws this node as chosen. There
    /// is one selection; these are two ways of pointing at it.
    ///
    /// A band handle clears it rather than selecting anything: the ladder's
    /// eleven filters have no row in that table to select.
    private func selectionGesture(_ size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                if case .filter(let id)? = handle(near: value.location, size) {
                    onFilterSelect?(id)
                } else {
                    onFilterSelect?(nil)
                }
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

    private func fraction(atX x: CGFloat, _ size: CGSize) -> Double {
        Double(min(max((x - axisGutter) / plotWidth(size), 0), 1))
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
    ///
    /// The selected filter gets the same treatment while nothing is being
    /// pointed at, so choosing a row in the parametric table shows what that
    /// row is doing to the sound and not only which node it owns.
    private func drawHighlightedFilterCurve(_ context: GraphicsContext, _ size: CGSize) {
        guard let handle = activeDrag ?? activeHover ?? selectedFilterID.map(Handle.filter) else { return }
        let source: EQFilter?
        switch handle {
        case .band(let slot): source = bands[safe: slot]
        case .filter(let id): source = freeFilters.first { $0.id == id }
        }
        guard let source else { return }
        let tint = source.isBand ? Color.coreEQAccent : BandColor.at(source.colorIndex).color
        let biquad = Biquad(filter: source, sampleRate: sampleRate)
        let axis = axis(size)

        var response = Path()
        for step in 0..<Self.curvePointCount {
            let fraction = Double(step) / Double(Self.curvePointCount - 1)
            let dB = biquad.magnitudeDB(at: axis.frequency(atFraction: fraction), sampleRate: sampleRate)
            let point = CGPoint(x: axisGutter + CGFloat(fraction) * plotWidth(size), y: yPosition(dB, size))
            if step == 0 {
                response.move(to: point)
            } else {
                response.addLine(to: point)
            }
        }

        context.stroke(
            response,
            with: .color(tint.opacity(0.5)),
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
        // A tint under the line, not a block of colour. A boosted curve sits
        // above zero across the whole range, so the area beneath it is most of
        // the plot — at any real opacity that area, not the curve, becomes the
        // subject.
        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [.coreEQAccent.opacity(0.10), .coreEQAccent.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: floor)
            )
        )

        context.stroke(curve, with: .color(.coreEQAccent), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }

    private func drawBandMarkers(_ context: GraphicsContext, _ size: CGSize) {
        for (slot, band) in bands.enumerated() {
            let isHighlighted = (activeDrag ?? activeHover) == .band(slot)
            // Bands the processor cannot render (at or above Nyquist for the
            // current sample rate) are shown dimmed. A band at 0 dB is not one
            // of them — it is flat, which is a value like any other.
            let isActive = band.isEnabled && Biquad.isRealisable(
                frequency: band.frequency, sampleRate: sampleRate
            )
            let center = bandHandleCenter(band, size)
            let radius: CGFloat = isHighlighted ? 5 : 4
            let dot = circle(at: center, radius: radius)

            // Logic Pro's handle: a white core inside an accent ring, which
            // stays legible over both the fill and the grid.
            context.fill(dot, with: .color(.white.opacity(isActive ? 0.95 : 0.35)))
            context.stroke(
                dot,
                with: .color(.coreEQAccent.opacity(isActive ? 1.0 : 0.35)),
                lineWidth: isHighlighted ? 2 : 1.5
            )
        }

        // The value goes here, at the handle, whether the band was moved by
        // dragging this point or by dragging its slider below. It is the number
        // and the shape of the change in one place, which is the reason the
        // curve is the biggest thing in the window.
        if case .band(let slot)? = activeDrag, let band = bands[safe: slot] {
            drawGainLabel(context, size, center: bandHandleCenter(band, size), gain: band.gain)
        }
    }

    /// Free filters, drawn larger than the band handles and numbered.
    ///
    /// The size difference is the visual half of the same distinction the drag
    /// enforces: these are the points that move in two axes.
    ///
    /// Each node takes its band's own colour rather than the curve's green, so
    /// the row in the parametric list and the point on the graph are visibly
    /// the same band. The curve itself stays green: it is the output, and the
    /// output belongs to no single band.
    private func drawFilterNodes(_ context: GraphicsContext, _ size: CGSize) {
        for (index, filter) in freeFilters.enumerated() {
            let tint = BandColor.at(filter.colorIndex).color
            let isHighlighted = (activeDrag ?? activeHover) == .filter(filter.id)
            let isSelected = selectedFilterID == filter.id
            // Dimmed only when the band is switched off or its frequency can't
            // be rendered at this sample rate. Not when its gain is 0: a band
            // that was just added sits at 0 dB, and dimming it there says it is
            // inactive when it is simply flat.
            let isActive = filter.isEnabled && Biquad.isRealisable(
                frequency: filter.frequency, sampleRate: sampleRate
            )
            let center = filterNodeCenter(filter, size)
            // Large enough for the number inside to be read rather than
            // guessed at, which is the whole point of putting it there: the
            // number is how a node is matched to its row in the table.
            let radius: CGFloat = isHighlighted ? 10 : 9
            let core = circle(at: center, radius: radius)

            // Selection is a heavier outline, exactly as it is on a band
            // slider's knob — no ring drawn around the point. The selected
            // filter's own response is already on the plot as a dashed line,
            // and that says which band is chosen better than a halo does.
            context.fill(core, with: .color(.white.opacity(isActive ? 0.95 : 0.35)))
            context.stroke(
                core,
                with: .color(tint.opacity(isActive ? 1.0 : 0.35)),
                lineWidth: isHighlighted || isSelected ? 3 : 2
            )

            let number = Text("\(index + 1)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.black.opacity(isActive ? 0.75 : 0.3))
            context.draw(number, at: center, anchor: .center)
        }

        if case .filter(let id)? = activeDrag, let filter = freeFilters.first(where: { $0.id == id }) {
            let center = filterNodeCenter(filter, size)
            let text = filter.kind.usesGain
                ? "\(BandFormat.frequency(filter.frequency)) Hz  \(BandFormat.gain(filter.gain))"
                : "\(BandFormat.frequency(filter.frequency)) Hz"
            drawLabel(context, size, center: center, text: text)
        }
    }

    private func circle(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
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
        let axis = axis(size)

        return (0..<Self.curvePointCount).map { index in
            let fraction = Double(index) / Double(Self.curvePointCount - 1)
            let frequency = axis.frequency(atFraction: fraction)
            let dB = biquads.reduce(preamp) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
            return CGPoint(x: axisGutter + CGFloat(fraction) * plotWidth(size), y: yPosition(dB, size))
        }
    }

    // MARK: - Coordinate mapping

    /// The mapping this plot draws against, rebuilt per layout pass.
    private func axis(_ size: CGSize) -> ResponseAxis {
        ResponseAxis(anchors: anchors, gutter: axisGutter, width: size.width)
    }

    /// Only the drag path needs this outside a loop; everywhere else builds the
    /// axis once and asks it directly.
    private func frequency(atFraction t: Double) -> Double {
        ResponseAxis(anchors: anchors, gutter: axisGutter, width: 0).frequency(atFraction: t)
    }

    /// Horizontal extent of the plot, to the right of the dB-label gutter.
    private func plotWidth(_ size: CGSize) -> CGFloat {
        max(size.width - axisGutter, 1)
    }

    private func xPosition(_ frequency: Double, _ size: CGSize) -> CGFloat {
        axis(size).x(frequency)
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


/// Frequency-to-x mapping for the response plot.
///
/// Pulled out of the view so the live backdrop and the static plot can share
/// one definition of where a frequency sits. Two copies would be two chances
/// for the spectrum to drift sideways from the curve it sits behind.
struct ResponseAxis: Equatable {
    /// Band centre frequencies, ascending.
    let anchors: [Double]
    /// Width reserved at the left for the dB labels.
    let gutter: CGFloat
    let width: CGFloat

    var plotWidth: CGFloat { max(width - gutter, 1) }

    /// X-axis aligned with the slider columns underneath the plot: band `i`
    /// sits at fraction `(i + 0.5) / bandCount`, and frequencies between bands
    /// interpolate logarithmically. Beyond the outermost bands the axis
    /// extrapolates using the neighbouring octave ratio.
    func fraction(of frequency: Double) -> Double {
        let n = anchors.count
        guard n >= 2, frequency > 0 else { return 0.5 }
        let slot = 1.0 / Double(n)
        func center(_ i: Int) -> Double { (Double(i) + 0.5) * slot }

        if frequency <= anchors[0] {
            return center(0) + slot * log(frequency / anchors[0]) / log(anchors[1] / anchors[0])
        }
        if frequency >= anchors[n - 1] {
            return center(n - 1) + slot * log(frequency / anchors[n - 1]) / log(anchors[n - 1] / anchors[n - 2])
        }
        for i in 0..<(n - 1) where frequency <= anchors[i + 1] {
            return center(i) + slot * log(frequency / anchors[i]) / log(anchors[i + 1] / anchors[i])
        }
        return 1
    }

    /// Inverse of `fraction(of:)`, used to sweep the curve and to turn a pointer
    /// position into the frequency a dragged filter should take.
    func frequency(atFraction t: Double) -> Double {
        let n = anchors.count
        guard n >= 2 else { return 1_000 }
        // Position in band-index units, measured from the first band's centre.
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

    func x(_ frequency: Double) -> CGFloat {
        gutter + CGFloat(min(max(fraction(of: frequency), 0), 1)) * plotWidth
    }
}

/// The analyzer backdrop, on its own layer.
///
/// This is the only part of the plot that changes at frame rate, and it is the
/// only view that observes the analyzer — so a spectrum tick invalidates this
/// and nothing else. Folded into the main canvas it took the grid's fourteen
/// text labels, the curve's biquad sweep, and the whole enclosing window's body
/// down with it, sixty times a second.
struct SpectrumBackdrop: View {
    @ObservedObject var spectrum: SpectrumAnalyzer
    let axis: ResponseAxis
    let plotHeight: CGFloat

    var body: some View {
        Canvas { context, _ in
            let points = spectrum.points
            // Silence would otherwise stroke a flat line along the floor of the
            // plot, which reads as a stray rule under the frequency labels.
            guard points.count > 1, points.contains(where: { $0.level > 0.02 }) else { return }

            var line = Path()
            for (index, point) in points.enumerated() {
                let position = CGPoint(x: axis.x(point.frequency), y: plotHeight * (1 - CGFloat(point.level)))
                if index == 0 {
                    line.move(to: position)
                } else {
                    line.addLine(to: position)
                }
            }

            var fill = line
            fill.addLine(to: CGPoint(x: axis.x(points[points.count - 1].frequency), y: plotHeight))
            fill.addLine(to: CGPoint(x: axis.x(points[0].frequency), y: plotHeight))
            fill.closeSubpath()

            // Deliberately faint: the analyzer is context for the curve, not a
            // second subject.
            context.fill(fill, with: .color(.primary.opacity(0.05)))
            context.stroke(line, with: .color(.primary.opacity(0.13)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
