import SwiftUI

/// The main EQ window: profile selector, one vertical gain slider per band,
/// global bypass toggle, and an engine status footer.
struct MainWindowView: View {
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var audioEngine: AudioEngine
    @ObservedObject var spectrum: SpectrumAnalyzer

    var body: some View {
        VStack(spacing: 20) {
            header
            responseCurve
            bandSliders
            footer
        }
        .padding(24)
        .frame(minWidth: 680)
        .onAppear { spectrum.start() }
        .onDisappear { spectrum.stop() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Picker("Profile", selection: profileBinding) {
                ForEach(profileManager.listProfiles()) { profile in
                    Text(profile.name).tag(profile.name)
                }
            }
            .fixedSize()

            if profileManager.isModified {
                Button("Reset") {
                    profileManager.resetToActiveProfile()
                }
                .help("Restore the active profile’s original band values")
            }

            Spacer()

            Toggle("Enabled", isOn: $audioEngine.isEnabled)
                .toggleStyle(.switch)
        }
    }

    private var responseCurve: some View {
        FrequencyResponseView(
            bands: profileManager.currentBands,
            sampleRate: audioEngine.sampleRate,
            spectrum: spectrum.points,
            onGainChange: { index, gain in profileManager.setGain(gain, forBandAt: index) },
            onBandReset: { index in profileManager.resetBand(at: index) }
        )
        .frame(height: 170)
        .opacity(audioEngine.isEnabled ? 1.0 : 0.5)
        .allowsHitTesting(audioEngine.isEnabled)
        .help("Drag a point up or down to adjust its band; double-click a point to reset it to the profile value")
    }

    private var bandSliders: some View {
        // Zero spacing keeps each column's center at (i + 0.5) / bandCount of
        // the full width, exactly matching the response plot's band axis.
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(profileManager.currentBands.indices, id: \.self) { index in
                bandControl(at: index)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(audioEngine.isEnabled ? 1.0 : 0.5)
    }

    private func bandControl(at index: Int) -> some View {
        let band = profileManager.currentBands[index]
        return VStack(spacing: 6) {
            Text(String(format: "%+.1f", band.gain))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            VerticalGainSlider(
                value: gainBinding(at: index),
                range: BuiltInProfiles.gainRange,
                step: 0.5,
                isEnabled: audioEngine.isEnabled,
                onReset: { profileManager.resetBand(at: index) }
            )
            .frame(width: 44, height: 150)

            Text(frequencyLabel(band.frequency))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard audioEngine.isEnabled else { return }
                profileManager.resetBand(at: index)
            }
        )
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(audioEngine.status.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    private var statusColor: Color {
        switch audioEngine.status {
        case .running: return audioEngine.isEnabled ? .green : .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }

    private var profileBinding: Binding<String> {
        Binding(
            get: { profileManager.activeProfileName },
            set: { profileManager.setActiveProfile(name: $0) }
        )
    }

    private func gainBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard profileManager.currentBands.indices.contains(index) else { return 0 }
                return profileManager.currentBands[index].gain
            },
            set: { profileManager.setGain($0, forBandAt: index) }
        )
    }

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

/// Pure-SwiftUI vertical gain slider.
///
/// The system `Slider` is AppKit-backed on macOS and consumes mouse events
/// before SwiftUI gestures on enclosing views run, which made the
/// Lightroom-style double-click reset unreachable over the slider area.
/// Drawing the control natively gives full gesture control: drag adjusts the
/// gain (absolute, snapped to `step`), double-click resets the band, and a
/// plain single click deliberately does nothing so the reset is flicker-free.
private struct VerticalGainSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let isEnabled: Bool
    let onReset: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private static let thumbDiameter: CGFloat = 16
    private static let trackWidth: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let midX = geometry.size.width / 2
            let travel = height - Self.thumbDiameter
            let span = range.upperBound - range.lowerBound
            let thumbY = yPosition(for: value, travel: travel)
            let zeroY = yPosition(for: 0, travel: travel)

            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: Self.trackWidth, height: height)
                    .position(x: midX, y: height / 2)

                // Filled section between 0 dB and the current value.
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: Self.trackWidth, height: abs(thumbY - zeroY))
                    .position(x: midX, y: (thumbY + zeroY) / 2)

                // 0 dB tick.
                Rectangle()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 14, height: 1)
                    .position(x: midX, y: zeroY)

                Circle()
                    .fill(colorScheme == .dark ? Color(white: 0.8) : .white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: Self.thumbDiameter, height: Self.thumbDiameter)
                    .position(x: midX, y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        guard isEnabled, travel > 0, span > 0 else { return }
                        let fraction = 1.0 - Double((drag.location.y - Self.thumbDiameter / 2) / travel)
                        let raw = range.lowerBound + span * min(max(fraction, 0), 1)
                        value = (raw / step).rounded() * step
                    }
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

    private func yPosition(for gain: Double, travel: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return Self.thumbDiameter / 2 + travel / 2 }
        let fraction = (gain - range.lowerBound) / span
        return Self.thumbDiameter / 2 + travel * CGFloat(1.0 - fraction)
    }
}
