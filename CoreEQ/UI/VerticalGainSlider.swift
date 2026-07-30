import AppKit
import SwiftUI

/// The window's own background material, for the content column to sit on.
///
/// A flat `Color(nsColor: .windowBackgroundColor)` fill is not the same surface:
/// the titlebar and the sidebar are both vibrant materials, and against them the
/// solid colour reads markedly darker, so the column looked like a sunken well
/// rather than the page the blocks rest on. Taking the real material makes the
/// three continuous.
struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Pure-SwiftUI vertical gain slider.
///
/// The system `Slider` is AppKit-backed on macOS and consumes mouse events
/// before SwiftUI gestures on enclosing views run, which made the
/// Lightroom-style double-click reset unreachable over the slider area.
/// Drawing the control natively gives full gesture control: drag adjusts the
/// gain (absolute, snapped to `step`), double-click resets the band, and a
/// plain single click deliberately does nothing so the reset is flicker-free.
struct VerticalGainSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let isEnabled: Bool
    /// Hovered or being dragged: the only state in which the band shows its
    /// accent colour, so a row at rest is a quiet ladder of grey tracks.
    let isActive: Bool
    let onDragChange: (Bool) -> Void
    let onReset: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    static var knobDiameter: CGFloat { Theme.BandRow.knobDiameter }
    private static var trackWidth: CGFloat { Theme.BandRow.trackWidth }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let midX = geometry.size.width / 2
            let travel = height - Self.knobDiameter
            let span = range.upperBound - range.lowerBound
            let knobY = Self.knobCenterY(for: value, in: height, range: range)
            let bottomY = Self.knobCenterY(for: range.lowerBound, in: height, range: range)

            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: Self.trackWidth, height: height - Self.knobDiameter / 2)
                    .position(x: midX, y: height / 2)

                // Travelled portion, from the bottom of the track up to the
                // knob. Only while active — see `isActive`.
                if isActive {
                    Capsule()
                        .fill(Color.coreEQAccent)
                        .frame(width: Self.trackWidth, height: max(bottomY - knobY, 0))
                        .position(x: midX, y: (knobY + bottomY) / 2)
                }

                Circle()
                    .fill(colorScheme == .dark ? Color(white: 0.85) : .white)
                    .overlay(
                        Circle().strokeBorder(
                            isActive ? Color.coreEQAccent : Color.black.opacity(0.22),
                            lineWidth: isActive ? 2 : 0.5
                        )
                    )
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                    .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                    .position(x: midX, y: knobY)
            }
            .animation(.easeOut(duration: 0.12), value: isActive)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        guard isEnabled, travel > 0, span > 0 else { return }
                        onDragChange(true)
                        let fraction = 1.0 - Double((drag.location.y - Self.knobDiameter / 2) / travel)
                        let raw = range.lowerBound + span * min(max(fraction, 0), 1)
                        value = (raw / step).rounded() * step
                    }
                    .onEnded { _ in onDragChange(false) }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard isEnabled else { return }
                    onReset()
                }
            )
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
        }
    }

    /// Centre of the knob for a given gain. Shared with the dB scale beside the
    /// row so its marks sit exactly level with the knob travel.
    static func knobCenterY(for gain: Double, in height: CGFloat, range: ClosedRange<Double>) -> CGFloat {
        let travel = height - knobDiameter
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return knobDiameter / 2 + travel / 2 }
        let fraction = (gain - range.lowerBound) / span
        return knobDiameter / 2 + travel * CGFloat(1.0 - fraction)
    }
}
