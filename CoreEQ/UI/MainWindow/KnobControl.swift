import AppKit
import SwiftUI

/// A circular control: an arc that reads as a value at a glance, and the same
/// drag, scroll, and double-click the band sliders answer to.
///
/// It is deliberately paired with a number field rather than replacing one. The
/// knob is for finding a value by feel while listening; the field is for typing
/// the one you already know. Neither can express the other's job, and the
/// parametric editor needs both.
struct KnobControl: View {
    @Binding var value: Double
    let scale: KnobScale
    /// The band's own colour, so the row and its node on the graph agree.
    let tint: Color
    let isEnabled: Bool
    /// Whether the arc grows from the top (a gain, which has a natural zero in
    /// the middle) or from the start of the sweep (a frequency or a Q, which
    /// have a natural minimum).
    var isBipolar = false
    /// Double-click target — 0 dB for gain, the same as double-clicking a band.
    var onReset: (() -> Void)?

    /// Vertical travel that covers the whole range. A little over an inch:
    /// enough to reach the ends in one gesture, fine enough to place a value
    /// without holding Shift.
    private static let dragTravel: CGFloat = 150
    /// The sweep, in turns: three quarters of the circle, opening at the
    /// bottom, as every hardware knob does.
    private static let sweep: CGFloat = 0.75
    private static let startAngle: CGFloat = 135

    @State private var dragAnchor: Double?
    @State private var isHovered = false

    var body: some View {
        let fraction = CGFloat(scale.fraction(of: value))
        let isLit = isEnabled && (isHovered || dragAnchor != nil)

        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweep)
                .stroke(Color.primary.opacity(0.14), style: strokeStyle)
                .rotationEffect(.degrees(Double(Self.startAngle)))

            Circle()
                .trim(from: arcBounds(for: fraction).lowerBound, to: arcBounds(for: fraction).upperBound)
                .stroke(tint.opacity(isEnabled ? 1.0 : 0.35), style: strokeStyle)
                .rotationEffect(.degrees(Double(Self.startAngle)))

            // The pointer says which way is up when the arc is nearly empty or
            // nearly full, where two arcs a detent apart look the same.
            GeometryReader { geometry in
                let radius = min(geometry.size.width, geometry.size.height) / 2
                Capsule()
                    .fill(Color.primary.opacity(isEnabled ? 0.55 : 0.2))
                    .frame(width: 1.5, height: radius * 0.42)
                    .offset(y: -radius * 0.5)
                    .rotationEffect(.degrees(Double(-135 + fraction * 270)))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .overlay {
            // A halo instead of a size change: the knob is in a table row, and
            // a control that grows on hover would nudge its neighbours.
            Circle()
                .strokeBorder(tint.opacity(isLit ? 0.28 : 0), lineWidth: 1)
                .padding(-2)
        }
        .animation(.easeOut(duration: 0.12), value: isLit)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    guard isEnabled else { return }
                    let anchor = dragAnchor ?? value
                    if dragAnchor == nil { dragAnchor = anchor }
                    // Relative to where the drag started, not to where the
                    // pointer is: an absolute mapping would make the value jump
                    // the moment a knob is touched anywhere but its current
                    // position.
                    let precision: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 4 : 1
                    let travelled = -drag.translation.height / (Self.dragTravel * precision)
                    let target = CGFloat(scale.fraction(of: anchor)) + travelled
                    value = scale.snapped(scale.value(at: Double(target)))
                }
                .onEnded { _ in dragAnchor = nil }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard isEnabled, let onReset else { return }
                onReset()
            }
        )
        // The same gesture the band sliders answer to, so a user who has learned
        // to scroll over one control doesn't have to learn a second habit here.
        // Over a knob the scroll adjusts rather than scrolls the list — the
        // knobs are small, deliberate targets, and everywhere else in the row
        // still scrolls.
        .scrollAdjustable(isEnabled: isEnabled) { steps in
            value = scale.stepped(value, by: steps)
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: scale.range)
        }
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: 3, lineCap: .round)
    }

    /// The filled part of the sweep: from the start for a unipolar parameter,
    /// out from the centre for a gain, so a cut and a boost of the same size
    /// read as mirror images.
    private func arcBounds(for fraction: CGFloat) -> ClosedRange<CGFloat> {
        let position = fraction * Self.sweep
        guard isBipolar else { return 0...max(position, 0.0001) }
        let center = Self.sweep / 2
        return min(center, position)...max(center, position)
    }
}
