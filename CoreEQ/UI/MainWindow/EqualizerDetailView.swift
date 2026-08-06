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

    /// The filter row and graph node currently pointed at, shared so selecting
    /// one highlights the other.
    @State private var selectedFilterID: UUID?

    /// Which editor the lower area is showing. Remembered across launches.
    ///
    /// A tab changes the controls and nothing else: the preset, the chain, the
    /// graph, and the audio are identical either side of a switch. The editing
    /// area is a fixed height for the same reason — nothing above it moves.
    @AppStorage("editorTab") private var tab: EditorTab = .graphic

    enum EditorTab: String {
        case graphic, parametric
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            header

            graph

            editor

            // Sits apart from the sections above it: it selects where the sound
            // goes, not how it's shaped.
            outputRow
                .padding(.top, 8)
        }
        .padding(.horizontal, Theme.Spacing.window)
        // The same gap the header has to the graph below it. The header sits
        // between two equal spaces rather than being crowded against the top
        // edge — deliberately `section`, so the two can't drift apart.
        .padding(.top, Theme.Spacing.section)
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

            Picker("Editor", selection: $tab) {
                Text("Graphic").tag(EditorTab.graphic)
                Text("Parametric").tag(EditorTab.parametric)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Editor")

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
            filters: profileManager.currentFilters,
            sampleRate: audioEngine.sampleRate,
            preamp: profileManager.currentPreamp,
            spectrum: spectrum.points,
            onBandGainChange: { slot, gain in profileManager.setGain(gain, forBandAt: slot) },
            onBandReset: { slot in profileManager.resetBand(at: slot) },
            onFilterMove: { id, frequency, gain in
                profileManager.setFilterFrequency(frequency, id: id)
                profileManager.setFilterGain(gain, id: id)
                selectedFilterID = id
            },
            onFilterReset: { id in profileManager.resetFilter(id: id) },
            onFilterCreate: { frequency, gain in
                selectedFilterID = profileManager.addFilter(frequency: frequency, gain: gain)
            },
            // Only while the Parametric tab is showing, so a stray double-click
            // on the graph can never conjure a band the user cannot see.
            allowsFilterCreation: tab == .parametric,
            showsBackground: false,
            // The plot fills the width; only its band ladder stops where the
            // slider strip does, so the sliders stay under their own points.
            bandAxisTrailingInset: Theme.globalGainWidth + Theme.Spacing.inner + Theme.blockPadding
        )
        // Vertical only: horizontal padding would shift the plot's band axis out
        // of line with the sliders underneath, which share `axisGutter`.
        .padding(.vertical, 16)
        // A low floor, not a comfortable one: every point the fixed sections
        // don't need goes here, so the graph is large whenever the window is,
        // and it compresses rather than pushing the window past the screen when
        // the window is small and the Filters section is open.
        //
        // The floor and `contentMinSize` are a pair. At the window minimum the
        // fixed sections plus the editing area come to ~640 pt with this floor;
        // raise it and the editor clips instead of the graph compressing.
        .frame(minHeight: 120, maxHeight: .infinity)
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
            HStack(spacing: 8) {
                Text("Band Levels")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 12)

                Toggle("", isOn: bandsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!audioEngine.isEnabled)
                    .help("Switch the band levels off to hear the filters on their own")
            }

            HStack(alignment: .top, spacing: 0) {
                gainAxis

                // Zero spacing keeps each column's center at (i + 0.5) /
                // bandCount of the remaining width, exactly matching the
                // response plot's band axis. The breathing room between sliders
                // comes from each track being far narrower than its column.
                HStack(alignment: .top, spacing: 0) {
                    ForEach(profileManager.bandFilters.indices, id: \.self) { slot in
                        bandControl(at: slot)
                    }
                }
            }
            .opacity(audioEngine.isEnabled ? 1.0 : 0.5)
        }
    }

    // MARK: - Editor

    /// The editing area: whichever editor the tab selects, with the output trim
    /// in a column beside it. Fixed height, so switching tabs never moves the
    /// graph.
    private var editor: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.inner) {
            Group {
                switch tab {
                case .graphic:
                    bandLevels
                case .parametric:
                    FilterListView(
                        profileManager: profileManager,
                        isEnabled: audioEngine.isEnabled,
                        selectedFilterID: $selectedFilterID
                    )
                }
            }
            // Both blocks fill the row, so the Graphic and Parametric tabs and
            // the Global Gain column all read as one band of equal height.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentBlock()

            GlobalGainView(profileManager: profileManager, isEnabled: audioEngine.isEnabled)
        }
        .frame(height: Theme.editorHeight)
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

    private func bandControl(at slot: Int) -> some View {
        let band = profileManager.bandFilters[slot]
        let isActive = draggingBand == slot || hoveredBand == slot
        let total = profileManager.totalGain(at: band.frequency, sampleRate: audioEngine.sampleRate)

        return VStack(spacing: 6) {
            // Reserved height and nothing else. The bubble is an overlay so its
            // width can never widen the column — it varies with the text, and
            // the two-value form is wider than the one-value form, so in the
            // layout flow it made the gap between sliders depend on whether the
            // chain happened to total something different at that band.
            //
            // Column width must depend on the band count alone: the graph places
            // band `i` at (i + 0.5) / bandCount of its plot, and the sliders only
            // sit under their own points because they divide the same width the
            // same way.
            Color.clear
                .frame(width: Theme.BandRow.columnWidth, height: Theme.BandRow.readoutHeight)
                .overlay(gainReadout(band: band.gain, total: total, visible: isActive))

            VerticalGainSlider(
                value: gainBinding(at: slot),
                range: BuiltInProfiles.gainRange,
                step: 0.5,
                isEnabled: audioEngine.isEnabled,
                isActive: isActive,
                totalGain: total,
                onDragChange: { isDragging in draggingBand = isDragging ? slot : nil },
                onReset: { profileManager.resetBand(at: slot) }
            )
            .frame(width: Theme.BandRow.columnWidth, height: Theme.BandRow.sliderHeight)
            .accessibilityLabel("\(BandFormat.frequency(band.frequency)) hertz")
            .accessibilityValue(
                String(format: "%+.1f decibels, chain total %+.1f decibels", band.gain, total)
            )

            Text(BandFormat.frequency(band.frequency))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .onHover { isInside in
            if isInside {
                hoveredBand = slot
            } else if hoveredBand == slot {
                hoveredBand = nil
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard audioEngine.isEnabled else { return }
                profileManager.resetBand(at: slot)
            }
        )
        .contextMenu {
            Button("Reset Band") { profileManager.resetBand(at: slot) }
            Divider()
            // A move, not a conversion: the lifted filter keeps this band's
            // frequency, gain, and Q, and the slot stays in the strip at 0 dB,
            // so the sound is identical either side of the command.
            Button("Edit as Filter…") {
                if let id = profileManager.editBandAsFilter(slot: slot) {
                    selectedFilterID = id
                    // Follow the filter to where it now lives, or the command
                    // would look like it did nothing.
                    tab = .parametric
                }
            }
            .disabled(!profileManager.canAddFilter)
        }
    }

    /// Floating gain value above the slider, shown only while its band is
    /// hovered or being dragged so an untouched row stays quiet.
    ///
    /// Two numbers whenever they differ: the band's own gain, which is what this
    /// slider sets, and what the whole chain totals at this frequency, which is
    /// what you hear. The gap between them is always some other filter reaching
    /// this far, and showing it is what keeps the slider honest without letting
    /// it report a value it doesn't control.
    private func gainReadout(band: Double, total: Double, visible: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(BandFormat.gain(band))
                    .foregroundStyle(Color.coreEQAccent)

                if abs(total - band) > 0.05 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(BandFormat.gain(total))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
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

    /// A plain label and the current device, the way Finder and Music name one —
    /// no card of its own. The device is a native pop-up button while there is
    /// something to choose between, and plain text when there isn't. An engine
    /// warning joins it on the rare occasions the audio path isn't healthy.
    private var outputRow: some View {
        HStack(spacing: 12) {
            Text("Output")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if outputs.hasChoice {
                devicePicker
            } else {
                deviceName
            }

            Spacer(minLength: 16)

            volumeControl

            if let warning = engineWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(audioEngine.status.description)
            }
        }
    }

    /// System output volume, on the row that already says where the sound is
    /// going. Not CoreEQ's own gain — this moves the output device itself, the
    /// same value the Sound menu and the volume keys show, and it follows those
    /// when they change it.
    private var volumeControl: some View {
        HStack(spacing: 8) {
            Button {
                outputs.toggleMuted()
            } label: {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!outputs.canSetVolume)
            .help(outputs.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(outputs.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { Double(outputs.volume) },
                    set: { outputs.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .frame(width: 112)
            .disabled(!outputs.canSetVolume)
            .accessibilityLabel("Output volume")

            Text(outputs.canSetVolume ? "\(Int((outputs.volume * 100).rounded()))%" : "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        // A device with no settable volume — many digital outputs — keeps the
        // row's shape rather than removing the control, so switching devices
        // doesn't reflow the row.
        .opacity(outputs.canSetVolume ? 1.0 : 0.4)
        .help(outputs.canSetVolume ? "System output volume" : "This output has no adjustable volume")
    }

    private var volumeSymbol: String {
        guard outputs.canSetVolume, !outputs.isMuted else { return "speaker.slash.fill" }
        switch outputs.volume {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private var devicePicker: some View {
        Picker("Output Device", selection: outputSelection) {
            ForEach(outputs.devices) { device in
                Label(device.name, systemImage: device.symbolName).tag(Optional(device.id))
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
    }

    /// The single output, or the lack of any: the same icon and name the pop-up
    /// would carry, without the button chrome that would promise a choice the
    /// machine can't offer. The leading inset stands in for the pop-up's own, so
    /// the name starts where it did when a second device was plugged in.
    private var deviceName: some View {
        Label(outputs.defaultDeviceName, systemImage: outputs.defaultDeviceSymbolName)
            .font(.system(size: 13))
            .foregroundStyle(outputs.devices.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .padding(.leading, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Output device")
            .accessibilityValue(outputs.defaultDeviceName)
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

    private func gainBinding(at slot: Int) -> Binding<Double> {
        Binding(
            get: { profileManager.bandFilters[safe: slot]?.gain ?? 0 },
            set: { profileManager.setGain($0, forBandAt: slot) }
        )
    }

    private var bandsEnabled: Binding<Bool> {
        Binding(
            get: { profileManager.areBandsEnabled },
            set: { profileManager.setBandsEnabled($0) }
        )
    }
}
