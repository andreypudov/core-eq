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
    /// Deliberately *not* observed here. The analyzer publishes at frame rate,
    /// and observing it at this level rebuilt the header, the editor, the band
    /// strip, and the output row on every tick. Only `SpectrumBackdrop`, inside
    /// the plot, subscribes to it.
    let spectrum: SpectrumAnalyzer
    /// Owned by the app delegate, not by this view: it has to keep following
    /// the default device while the window is closed.
    @ObservedObject var outputs: AudioDeviceList

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

    /// The editor switcher, where the sound is going, a way back to the saved
    /// preset, and the master switch.
    ///
    /// No "Equalizer" title and no preset pop-up: the window is the equalizer,
    /// and the sidebar already lists every preset with the active one ticked.
    /// Naming both again here was furniture.
    private var header: some View {
        ZStack {
            // Centred on the content column — the same centreline the plot and
            // the volume control below it use.
            deviceControl

            HStack(spacing: 12) {
                Picker("Editor", selection: $tab) {
                    Text("Graphic").tag(EditorTab.graphic)
                    Text("Parametric").tag(EditorTab.parametric)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Editor")

                Spacer(minLength: 16)

                if let warning = engineWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(audioEngine.status.description)
                }

                Button("Reset") { profileManager.resetToActiveProfile() }
                    .disabled(!profileManager.isModified)
                    .help("Discard changes and return to the saved preset")

                // Furthest right, and unlabelled: it governs everything in the
                // window, so it belongs at the end of the row rather than inside
                // any one section. Deliberately not dimmed with the rest when
                // off — it is the way back on.
                Toggle("", isOn: $audioEngine.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Equalizer")
                    .help(audioEngine.isEnabled ? "Turn the equalizer off" : "Turn the equalizer on")
            }
        }
        .frame(height: Theme.headerHeight)
    }

    /// The device, as a pop-up while there is something to choose between and
    /// plain text when there isn't.
    @ViewBuilder
    private var deviceControl: some View {
        if outputs.hasChoice {
            devicePicker
        } else {
            deviceName
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
            spectrum: spectrum,
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
            showsBackground: false
        )
        // Vertical only: the plot spans its own width from 32 Hz to 20 kHz, so
        // horizontal padding would only shrink the range on show.
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
                .strokeBorder(Theme.blockBorder, lineWidth: 1)
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
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                // The gain readout reads out here rather than in a strip above
                // the tracks. A strip would push every track down by its own
                // height whether or not anything was in it; the heading row has
                // the space already, and more of it than a 26 pt column does.
                bandReadout
                    .frame(height: Theme.BandRow.readoutHeight)

                Spacer(minLength: 12)

                Toggle("", isOn: bandsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!audioEngine.isEnabled)
                    .help("Switch the band levels off to hear the filters on their own")
            }
            .frame(height: Theme.BandRow.headingHeight)

            // The tracks take whatever the heading and captions leave — the same
            // arithmetic the Preamp column runs, so the two start and end level.
            GeometryReader { proxy in
                let trackHeight = max(
                    proxy.size.height - Theme.BandRow.chromeHeight,
                    Theme.BandRow.minSliderHeight
                )
                HStack(alignment: .top, spacing: 0) {
                    gainAxis(trackHeight: trackHeight)

                    // Zero spacing keeps each column's center at (i + 0.5) /
                    // bandCount of the remaining width. The breathing room
                    // between sliders comes from each track being far narrower
                    // than its column.
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(profileManager.bandFilters.indices, id: \.self) { slot in
                            bandControl(at: slot, trackHeight: trackHeight)
                        }
                    }
                    // The one reference the strip is read against, the way the
                    // plot above has it. Without it a row of knobs says how far
                    // each band moved but not from what.
                    .background(alignment: .top) {
                        Rectangle()
                            .fill(Theme.blockBorder)
                            .frame(height: 1)
                            .offset(
                                y: VerticalGainSlider.knobCenterY(
                                    for: 0, in: trackHeight, range: BuiltInProfiles.gainRange
                                )
                            )
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

    private func gainAxis(trackHeight: CGFloat) -> some View {
        GainScale(range: BuiltInProfiles.gainRange, trackHeight: trackHeight, side: .leading)
            .frame(width: Theme.axisGutter, alignment: .trailing)
    }

    private func bandControl(at slot: Int, trackHeight: CGFloat) -> some View {
        let band = profileManager.bandFilters[slot]
        let isActive = draggingBand == slot || hoveredBand == slot

        return VStack(spacing: 6) {
            VerticalGainSlider(
                value: gainBinding(at: slot),
                range: BuiltInProfiles.gainRange,
                step: 0.5,
                isEnabled: audioEngine.isEnabled,
                isActive: isActive,
                onDragChange: { isDragging in draggingBand = isDragging ? slot : nil },
                onReset: { profileManager.resetBand(at: slot) }
            )
            .frame(width: Theme.BandRow.columnWidth, height: trackHeight)
            .accessibilityLabel("\(BandFormat.frequency(band.frequency)) hertz")
            .accessibilityValue(String(format: "%+.1f decibels", band.gain))

            Text(BandFormat.frequency(band.frequency))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(height: Theme.BandRow.labelHeight)
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

    /// What the hovered or dragged band is doing, shown beside the heading.
    ///
    /// Two values whenever they differ: the band's own gain, which is what its
    /// slider sets, and what the whole chain totals at that frequency, which is
    /// what you hear. The gap between them is always some other filter reaching
    /// this far, and showing it is what keeps the slider honest without letting
    /// it report a value it doesn't control.
    @ViewBuilder
    private var bandReadout: some View {
        let slot = draggingBand ?? hoveredBand
        if let slot, let band = profileManager.bandFilters[safe: slot] {
            let total = profileManager.totalGain(at: band.frequency, sampleRate: audioEngine.sampleRate)
            HStack(spacing: 5) {
                Text(BandFormat.frequency(band.frequency))
                    .foregroundStyle(.secondary)
                Text(BandFormat.gain(band.gain))
                    .foregroundStyle(Color.coreEQAccent)
                if abs(total - band.gain) > 0.05 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(BandFormat.gain(total))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .transition(.opacity)
        }
    }

    // MARK: - Output

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
        .frame(width: Theme.outputControlWidth)
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
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: Theme.outputControlWidth, alignment: .center)
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
