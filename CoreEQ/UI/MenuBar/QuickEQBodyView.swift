import AppKit
import SwiftUI

/// Quick EQ body: the compact live response graph above three tone sliders
/// (Bass / Mid / Treble). Dragging a slider calls back with the axis and its
/// snapped value; `refreshGraph` redraws the curve from the new chain.
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
        filters: [EQFilter],
        tone: ProfileManager.ToneControls,
        sampleRate: Double,
        onToneChange: @escaping (Axis, Double) -> Void
    ) {
        self.sampleRate = sampleRate
        self.onToneChange = onToneChange
        self.graphHost = NSHostingView(rootView: FrequencyResponseView(filters: filters, sampleRate: sampleRate, minimal: true))
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

    /// Redraws the response curve after a tone change updates the chain.
    func refreshGraph(filters: [EQFilter]) {
        graphHost.rootView = FrequencyResponseView(filters: filters, sampleRate: sampleRate, minimal: true)
    }

    private func makeSliderRow(_ axis: Axis, value: Double) -> NSView {
        let name = NSTextField(labelWithString: axis.title)
        name.font = NSFont.menuFont(ofSize: 0)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let slider = ToneSlider(value: value, minValue: QuickTone.range.lowerBound, maxValue: QuickTone.range.upperBound, target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true
        slider.tag = axis.rawValue
        // The same gesture the band sliders and the graph's points answer to,
        // so "put it back" is one habit across the app rather than three.
        slider.onDoubleClick = { [weak self] in self?.reset(axis) }
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

    /// Back to the middle — which for a tone control is not "the saved value"
    /// but "no tilt at all", since these three are offsets laid over whatever
    /// preset is loaded.
    private func reset(_ axis: Axis) {
        sliders[axis]?.doubleValue = 0
        onToneChange(axis, 0)
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

/// A tone slider that answers a double-click by centring itself.
///
/// The second click is taken before `NSSlider` sees it, because the slider's
/// own `mouseDown` runs a tracking loop until the button comes up: handing it
/// the click would set the value from wherever the pointer happens to be, and
/// only then would the reset land — a visible flick on the way to the middle.
///
/// The *first* click of the pair still reaches the slider, so a double-click on
/// the track moves the knob there and then centres it. That is what a slider
/// does with a click; the pair still ends where it should.
@MainActor
private final class ToneSlider: NSSlider {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}
