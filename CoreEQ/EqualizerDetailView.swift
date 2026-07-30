import AppKit
import CoreAudio
import SwiftUI


/// Content column of the main window: the Equalizer heading with its preset
/// controls, the response graph, the band sliders, and the output selector.
///
/// The graph is the only element inside a container. Everything else is
/// separated by whitespace, so the column reads as one canvas rather than a
/// stack of panels.
struct EqualizerDetailView: View {
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var audioEngine: AudioEngine
    @ObservedObject var spectrum: SpectrumAnalyzer
    @StateObject private var outputs = AudioDeviceList()

    /// Band the pointer is over, and the band being dragged. Either one shows
    /// that band's gain readout; the rest of the row stays quiet.
    @State private var hoveredBand: Int?
    @State private var draggingBand: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            header

            graph

            bandLevels

            // Sits apart from the sections above it: it selects where the sound
            // goes, not how it's shaped.
            outputRow
                .padding(.top, 8)
        }
        .padding(.horizontal, Theme.Spacing.window)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackground())
        // Only preset switches animate: the name changes in the same
        // transaction as the band values, while a slider drag leaves it alone
        // and so stays perfectly responsive.
        .animation(.easeInOut(duration: 0.25), value: profileManager.activeProfileName)
        .onAppear { spectrum.start() }
        .onDisappear { spectrum.stop() }
    }

    // MARK: - Header

    /// Section title on the left, and the two controls that act on the whole
    /// equalizer on the right — the preset in effect, and a way back to it.
    private var header: some View {
        HStack(spacing: 12) {
            Text("Equalizer")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 16)

            Picker("Preset", selection: presetSelection) {
                ForEach(profileManager.profiles) { profile in
                    Text(profile.name).tag(profile.name)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 168)
            .accessibilityLabel("Preset")

            Button("Reset") { profileManager.resetToActiveProfile() }
                .disabled(!profileManager.isModified)
                .help("Discard changes and return to the saved preset")
        }
    }

    // MARK: - Graph

    /// The hero of the window: the only framed element, and the one that takes
    /// every point of leftover height.
    private var graph: some View {
        FrequencyResponseView(
            bands: profileManager.currentBands,
            sampleRate: audioEngine.sampleRate,
            spectrum: spectrum.points,
            onGainChange: { index, gain in profileManager.setGain(gain, forBandAt: index) },
            onBandReset: { index in profileManager.resetBand(at: index) },
            showsBackground: false
        )
        // Vertical only: horizontal padding would shift the plot's band axis out
        // of line with the sliders underneath, which share `axisGutter`.
        .padding(.vertical, 16)
        .frame(minHeight: 240, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .opacity(audioEngine.isEnabled ? 1.0 : 0.5)
        .allowsHitTesting(audioEngine.isEnabled)
        .help("Drag a point up or down to adjust its band; double-click a point to reset it")
    }

    // MARK: - Band levels

    private var bandLevels: some View {
        // Tight: the readout row above the sliders already supplies the gap
        // between the heading and the tracks.
        VStack(alignment: .leading, spacing: 2) {
            Text("Band Levels")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 0) {
                gainAxis

                // Zero spacing keeps each column's center at (i + 0.5) /
                // bandCount of the remaining width, exactly matching the
                // response plot's band axis. The breathing room between sliders
                // comes from each track being far narrower than its column.
                HStack(alignment: .top, spacing: 0) {
                    ForEach(profileManager.currentBands.indices, id: \.self) { index in
                        bandControl(at: index)
                    }
                }
            }
            .opacity(audioEngine.isEnabled ? 1.0 : 0.5)
        }
    }

    /// dB scale beside the sliders: a value at each extreme and at the
    /// reference, a dot at every major division. Positioned with the same
    /// geometry the slider uses, so the marks line up with the knob travel.
    private var gainAxis: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear

            ForEach(Self.axisTicks, id: \.self) { gain in
                HStack(spacing: 6) {
                    if Self.labelledTicks.contains(gain) {
                        Text(BandFormat.axisGain(gain))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    Circle()
                        .fill(Color.primary.opacity(0.2))
                        .frame(width: 3, height: 3)
                }
                .frame(height: 13)
                .offset(x: -8, y: VerticalGainSlider.knobCenterY(
                    for: gain,
                    in: Theme.BandRow.sliderHeight,
                    range: BuiltInProfiles.gainRange
                ) - 6.5)
            }
        }
        .frame(width: Theme.axisGutter, height: Theme.BandRow.sliderHeight)
        // Clears the readout row above the sliders so the scale starts level
        // with the top of the knob travel.
        .padding(.top, Theme.BandRow.readoutHeight + 6)
        .accessibilityHidden(true)
    }

    private static let axisTicks: [Double] = [12, 6, 0, -6, -12]
    private static let labelledTicks: Set<Double> = [12, 0, -12]

    private func bandControl(at index: Int) -> some View {
        let band = profileManager.currentBands[index]
        let isActive = draggingBand == index || hoveredBand == index

        return VStack(spacing: 6) {
            gainReadout(band.gain, visible: isActive)
                .frame(height: Theme.BandRow.readoutHeight)

            VerticalGainSlider(
                value: gainBinding(at: index),
                range: BuiltInProfiles.gainRange,
                step: 0.5,
                isEnabled: audioEngine.isEnabled,
                isActive: isActive,
                onDragChange: { isDragging in draggingBand = isDragging ? index : nil },
                onReset: { profileManager.resetBand(at: index) }
            )
            .frame(width: Theme.BandRow.columnWidth, height: Theme.BandRow.sliderHeight)
            .accessibilityLabel("\(BandFormat.frequency(band.frequency)) hertz")
            .accessibilityValue(String(format: "%+.1f decibels", band.gain))

            Text(BandFormat.frequency(band.frequency))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .onHover { isInside in
            if isInside {
                hoveredBand = index
            } else if hoveredBand == index {
                hoveredBand = nil
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard audioEngine.isEnabled else { return }
                profileManager.resetBand(at: index)
            }
        )
    }

    /// Floating gain value above the slider, shown only while its band is
    /// hovered or being dragged so an untouched row stays quiet.
    private func gainReadout(_ gain: Double, visible: Bool) -> some View {
        VStack(spacing: 0) {
            Text(BandFormat.gain(gain))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.coreEQAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

            DownwardPointer()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 9, height: 5)
        }
        .fixedSize()
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: visible)
    }

    // MARK: - Output

    /// A plain label and a native pop-up button, the way Finder and Music name
    /// a device — no card of its own. An engine warning joins it on the rare
    /// occasions the audio path isn't healthy.
    private var outputRow: some View {
        HStack(spacing: 12) {
            Text("Output")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Picker("Output Device", selection: outputSelection) {
                ForEach(outputs.devices) { device in
                    Label(device.name, systemImage: device.symbolName).tag(Optional(device.id))
                }
                if outputs.devices.isEmpty {
                    Text("No Output Device").tag(AudioDeviceID?.none)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // Large is the system's own bigger pop-up metrics — taller, roomier
            // inside — rather than a small button padded out by hand.
            .controlSize(.large)
            .fixedSize()
            .accessibilityLabel("Output device")
            .accessibilityValue(outputs.defaultDeviceName)

            if let warning = engineWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(audioEngine.status.description)
            }

            Spacer(minLength: 0)
        }
    }

    /// Nil while the engine is processing normally — a healthy engine needs no
    /// chrome in a window meant to look like a system utility.
    private var engineWarning: String? {
        switch audioEngine.status {
        case .running: return nil
        case .stopped: return "Audio engine stopped"
        case .failed: return "Audio engine error"
        }
    }

    // MARK: - Bindings

    private var presetSelection: Binding<String> {
        Binding(
            get: { profileManager.activeProfileName },
            set: { profileManager.setActiveProfile(name: $0) }
        )
    }

    private var outputSelection: Binding<AudioDeviceID?> {
        Binding(
            get: { outputs.defaultDeviceID },
            set: { if let id = $0 { outputs.select(id) } }
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
}

/// The little tail under the gain readout, pointing at the slider it belongs to.
private struct DownwardPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
