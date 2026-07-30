import AppKit
import SwiftUI

/// Quick EQ body: the compact live response graph above three tone sliders
/// (Bass / Mid / Treble). Dragging a slider calls back with the axis and its
/// snapped value; `refreshGraph` redraws the curve from the new bands.
@MainActor
final class QuickEQBodyView: NSView {
    enum Axis: Int, CaseIterable {
        case bass, mid, treble
        var title: String {
            switch self {
            case .bass: return "Bass"
            case .mid: return "Mid"
            case .treble: return "Treble"
            }
        }
    }

    private let graphHost: NSHostingView<FrequencyResponseView>
    private var sliders: [Axis: NSSlider] = [:]
    private let sampleRate: Double
    private let onToneChange: (Axis, Double) -> Void

    init(
        bands: [EQBand],
        tone: ProfileManager.ToneControls,
        sampleRate: Double,
        onToneChange: @escaping (Axis, Double) -> Void
    ) {
        self.sampleRate = sampleRate
        self.onToneChange = onToneChange
        self.graphHost = NSHostingView(rootView: FrequencyResponseView(bands: bands, sampleRate: sampleRate, minimal: true))
        super.init(frame: .zero)
        // View-based menu items are sized by Auto Layout: fix the content width
        // and let the vertical stack determine the height.
        translatesAutoresizingMaskIntoConstraints = false

        graphHost.translatesAutoresizingMaskIntoConstraints = false

        let rows = Axis.allCases.map { makeSliderRow($0, value: value(for: $0, in: tone)) }
        let stack = NSStackView(views: [graphHost] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: QuickEQMenuMetrics.contentWidth),
            graphHost.heightAnchor.constraint(equalToConstant: QuickEQMenuMetrics.graphHeight),
            graphHost.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: QuickEQMenuMetrics.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -QuickEQMenuMetrics.horizontalInset),
        ])
        rows.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Redraws the response curve after a tone change updates the bands.
    func refreshGraph(bands: [EQBand]) {
        graphHost.rootView = FrequencyResponseView(bands: bands, sampleRate: sampleRate, minimal: true)
    }

    private func makeSliderRow(_ axis: Axis, value: Double) -> NSView {
        let name = NSTextField(labelWithString: axis.title)
        name.font = NSFont.menuFont(ofSize: 0)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let slider = NSSlider(value: value, minValue: QuickTone.range.lowerBound, maxValue: QuickTone.range.upperBound, target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true
        slider.tag = axis.rawValue
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setAccessibilityLabel("\(axis.title) gain")
        sliders[axis] = slider

        // No numeric readout: Control Center sliders never show values, and the
        // live graph above already gives visual feedback.
        let row = NSStackView(views: [name, slider])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let axis = Axis(rawValue: sender.tag) else { return }
        // Snap to the 0.5 dB step used across the app for a subtle detent.
        let snapped = (sender.doubleValue * 2).rounded() / 2
        sender.doubleValue = snapped
        onToneChange(axis, snapped)
    }

    private func value(for axis: Axis, in tone: ProfileManager.ToneControls) -> Double {
        switch axis {
        case .bass: return tone.bass
        case .mid: return tone.mid
        case .treble: return tone.treble
        }
    }
}
