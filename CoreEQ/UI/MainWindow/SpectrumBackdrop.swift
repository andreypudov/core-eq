import AppKit
import Combine
import SwiftUI

/// The analyzer's trace behind the response curve, drawn on two Core Animation
/// shape layers rather than in a SwiftUI `Canvas`.
///
/// This is the only part of the plot that changes at frame rate. The view
/// subscribes to the analyzer itself and writes the layer paths directly, so a
/// tick invalidates nothing SwiftUI knows about and re-records no display list.
struct SpectrumBackdrop: NSViewRepresentable {
    /// Deliberately not observed: the subscription lives in the view.
    let spectrum: SpectrumAnalyzer
    let axis: ResponseAxis
    let plotHeight: CGFloat

    func makeNSView(context: Context) -> SpectrumBackdropView {
        let view = SpectrumBackdropView()
        view.follow(spectrum)
        return view
    }

    func updateNSView(_ view: SpectrumBackdropView, context: Context) {
        view.follow(spectrum)
        view.geometry = SpectrumBackdropGeometry(axis: axis, plotHeight: plotHeight)
    }
}

final class SpectrumBackdropView: NSView {
    // Deliberately faint: the analyzer is context for the curve, not a second
    // subject. Fractions of `labelColor`, which is what `.primary` is here.
    private static let fillOpacity: CGFloat = 0.05
    private static let lineOpacity: CGFloat = 0.13

    /// Holds the two shapes in top-left-origin coordinates, whatever the
    /// host view's own orientation is.
    private let container = CALayer()
    private let fillLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()

    private weak var spectrum: SpectrumAnalyzer?
    private var subscription: AnyCancellable?
    private var points: [SpectrumAnalyzer.Point] = []

    var geometry: SpectrumBackdropGeometry? {
        didSet {
            if geometry != oldValue { redraw() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        container.isGeometryFlipped = true
        fillLayer.lineWidth = 0
        lineLayer.fillColor = nil
        lineLayer.lineWidth = 1
        // Mitred, as the Canvas this replaced drew them: round joins blunt
        // every peak of the trace.
        lineLayer.lineJoin = .miter
        container.addSublayer(fillLayer)
        container.addSublayer(lineLayer)
        layer?.addSublayer(container)
        setAccessibilityElement(false)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Subscribes to `spectrum`, once per analyzer. `$points` sends before the
    /// property is stored, so the trace is drawn from the value it carries.
    func follow(_ spectrum: SpectrumAnalyzer) {
        guard spectrum !== self.spectrum else { return }
        self.spectrum = spectrum
        subscription = spectrum.$points.sink { [weak self] points in
            MainActor.assumeIsolated {
                self?.points = points
                self?.redraw()
            }
        }
    }

    /// Never a target: the gestures on the plot belong to the view above.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutAnimation { container.frame = bounds }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        withoutAnimation {
            for layer in [container, fillLayer, lineLayer] { layer.contentsScale = scale }
        }
    }

    private func redraw() {
        let paths = geometry?.paths(points)
        withoutAnimation {
            fillLayer.path = paths?.fill
            lineLayer.path = paths?.line
        }
    }

    private func applyColors() {
        var fill: CGColor?
        var line: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor
            fill = label.withAlphaComponent(label.alphaComponent * Self.fillOpacity).cgColor
            line = label.withAlphaComponent(label.alphaComponent * Self.lineOpacity).cgColor
        }
        withoutAnimation {
            fillLayer.fillColor = fill
            lineLayer.strokeColor = line
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
