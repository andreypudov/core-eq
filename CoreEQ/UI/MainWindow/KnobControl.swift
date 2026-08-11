import AppKit
import SwiftUI

/// How a knob's parameter maps onto its 270° sweep, and what values it is
/// allowed to land on.
///
/// Frequency and Q are logarithmic, because both are heard that way: 50 Hz to
/// 100 Hz is the octave 5 kHz to 10 kHz is, and Q 0.5 to 1 is the same halving
/// of bandwidth as 2 to 4. On a linear sweep of 20 Hz–20 kHz the whole bass
/// register would be the first two degrees, and on a linear 0.1–10 every Q
/// anyone reaches for would sit in the first tenth of the travel. Gain is
/// linear, matching the sliders and the dB scale beside the graph.
struct KnobScale {
    let range: ClosedRange<Double>
    let isLogarithmic: Bool
    /// One detent: an amount to add on a linear scale, a ratio to multiply by
    /// on a logarithmic one.
    private let detent: Double
    /// The resolution at a given value — what the knob rounds to, so it and the
    /// field beside it never disagree about where it is. A function of the
    /// value because a logarithmic parameter's useful precision is a proportion
    /// of it: 1 Hz matters at 40 Hz and is invisible at 12 kHz.
    private let grid: (Double) -> Double

    /// Gain: a fixed step in dB, the same half a decibel the band sliders snap
    /// to, so scrolling a knob and scrolling a slider can't land between each
    /// other's values.
    static func linear(_ range: ClosedRange<Double>, step: Double) -> KnobScale {
        KnobScale(range: range, isLogarithmic: false, detent: step, grid: { _ in step })
    }

    /// Frequency: a semitone per detent — the smallest interval anyone names —
    /// and three significant figures throughout.
    static func frequency(_ range: ClosedRange<Double>) -> KnobScale {
        KnobScale(range: range, isLogarithmic: true, detent: pow(2, 1.0 / 12.0)) { value in
            switch value {
            case ..<100: return 1
            case ..<1_000: return 5
            case ..<10_000: return 50
            default: return 100
            }
        }
    }

    /// Q: a quarter-tone per detent, rounded to the two decimals the field
    /// shows. Finer than frequency because the whole range is two decades
    /// rather than three and the ear hears the ends of it as a texture rather
    /// than a pitch.
    static func q(_ range: ClosedRange<Double>) -> KnobScale {
        KnobScale(range: range, isLogarithmic: true, detent: pow(2, 1.0 / 24.0), grid: { _ in 0.01 })
    }

    /// Where on the sweep a value sits, 0 at the start and 1 at the end.
    func fraction(of value: Double) -> Double {
        let clamped = value.clamped(to: range)
        guard isLogarithmic else {
            let span = range.upperBound - range.lowerBound
            return span > 0 ? (clamped - range.lowerBound) / span : 0
        }
        let low = log(range.lowerBound)
        let span = log(range.upperBound) - low
        return span > 0 ? (log(clamped) - low) / span : 0
    }

    func value(at fraction: Double) -> Double {
        let f = fraction.clamped(to: 0...1)
        guard isLogarithmic else {
            return range.lowerBound + (range.upperBound - range.lowerBound) * f
        }
        let low = log(range.lowerBound)
        return exp(low + (log(range.upperBound) - low) * f)
    }

    /// `value` moved by `steps` detents: a fixed amount on a linear scale, a
    /// fixed ratio on a logarithmic one.
    func stepped(_ value: Double, by steps: Int) -> Double {
        guard steps != 0 else { return value }
        let raw = isLogarithmic
            ? value * pow(detent, Double(steps))
            : value + Double(steps) * detent
        let moved = snapped(raw)

        // A ratio applied near the bottom of a logarithmic range can be smaller
        // than the value's own resolution — 3% of Q 0.1 rounds back to 0.1 —
        // and a control that answers a scroll by not moving reads as broken. So
        // a detent is guaranteed to be worth at least one step of the grid.
        guard moved == value else { return moved }
        return snapped(value + (steps > 0 ? grid(value) : -grid(value)))
    }

    func snapped(_ value: Double) -> Double {
        let resolution = grid(value)
        return ((value / resolution).rounded() * resolution).clamped(to: range)
    }
}

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
