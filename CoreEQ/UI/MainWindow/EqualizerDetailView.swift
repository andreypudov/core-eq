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
        // Three columns: the editor switcher, the device with the preset playing
        // on it, and the state of what is loaded. The device keeps the column's
        // centreline by giving the two sides equal, flexible halves — *not* by
        // floating over them, which is what let the engine warning slide
        // underneath the pop-up and collide with its chevron. Laid out in the
        // row, the sides can only push and truncate, never overlap.
        HStack(spacing: 12) {
            // The editor switcher used to sit here, a window's height away from
            // the block it governs. It is on that block's border now.
            Color.clear
                .frame(maxWidth: .infinity)

            deviceControl

            HStack(spacing: 10) {
                // The symbol alone, with the sentence in its tooltip. A rare
                // state should not hold a phrase's worth of the row open at
                // every other moment — and at the window's minimum width, that
                // phrase is what would push the preset out of the header.
                if let warning = engineWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .help(audioEngine.status.description)
                        .accessibilityLabel(warning)
                }

                Button("Revert") { profileManager.resetToActiveProfile() }
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
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: Theme.headerHeight)
    }

    /// Where the sound is going, and what it sounds like there.
    ///
    /// Two lines in one control, because they are one fact. Since per-device
    /// state landed, the preset, the unsaved edits and the trim have all followed
    /// the output device — and the window had nowhere that said so. The preset
    /// was named on the other side of the header, as far from the device as the
    /// row allows, which is the opposite of the truth.
    ///
    /// Under the device's own name, the preset reads as a property of it, which
    /// is what it is. Switching outputs changes both lines together, so the cause
    /// and the effect arrive in the same glance.
    @ViewBuilder
    private var deviceControl: some View {
        if outputs.hasChoice {
            Menu {
                ForEach(outputs.devices) { device in
                    Button {
                        outputs.select(device.id)
                    } label: {
                        // One line per row: an NSMenuItem has no subtitle, and
                        // SwiftUI offers no way to ask for one. Showing each
                        // device's own preset here would explain the second line
                        // below, and wants a spike against a real menu before it
                        // is designed around.
                        Label(device.name, systemImage: device.symbolName)
                    }
                }
            } label: {
                deviceLines
            }
            .menuStyle(.borderlessButton)
            .frame(width: Theme.outputControlWidth)
            .accessibilityLabel("Output device")
            .accessibilityValue(deviceAccessibilityValue)
        } else {
            // One output, or none: state it rather than offering a choice the
            // machine cannot honour.
            deviceLines
                .frame(width: Theme.outputControlWidth)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Output device")
                .accessibilityValue(deviceAccessibilityValue)
        }
    }

    private var deviceLines: some View {
        HStack(spacing: 7) {
            Image(systemName: outputs.defaultDeviceSymbolName)
                .font(.system(size: 13))
                .foregroundStyle(outputs.devices.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))

            VStack(alignment: .leading, spacing: 0) {
                Text(outputs.defaultDeviceName)
                    .font(.system(size: 13))
                    .foregroundStyle(outputs.devices.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Text(profileManager.activeProfileName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // The same mark the sidebar row uses for the same fact, in
                    // the colour the window gives to anything that came from the
                    // filters rather than from chrome.
                    if profileManager.isModified {
                        Circle()
                            .fill(Color.coreEQSignal)
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        // Status, not a second control: the preset is chosen in the sidebar, and
        // a line that looked clickable here would promise something this button
        // does not do.
        .allowsHitTesting(false)
    }

    private var deviceAccessibilityValue: String {
        let preset = profileManager.isModified
            ? "\(profileManager.activeProfileName), edited"
            : profileManager.activeProfileName
        return "\(outputs.defaultDeviceName), playing \(preset)"
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
            selectedFilterID: selectedFilterID,
            // Dragging a slider is dragging its handle on the curve — the plot
            // lights that handle up and puts the value beside it.
            stripHoveredBand: hoveredBand,
            stripDraggedBand: draggingBand,
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
            // The graph and the parametric table share one selection: clicking
            // a node highlights its row, choosing a row rings its node.
            onFilterSelect: { id in selectedFilterID = id },
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
        .help("Point at a handle to read its value; drag it to adjust; double-click to reset it")
    }

    // MARK: - Band levels

    private var bandLevels: some View {
        // No heading: the tab on the block's border names this, and its switch
        // sits on the same border.
        VStack(alignment: .leading, spacing: 2) {
            // The tracks take whatever the captions leave — the same arithmetic
            // the Preamp column runs, so the two start and end level.
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
            .borderLabel { editorTabs }
            .borderLabel(alignment: .topTrailing) { editorPower }

            GlobalGainView(profileManager: profileManager, isEnabled: audioEngine.isEnabled)
        }
        .frame(height: Theme.editorHeight)
        // Room for the labels hanging off the top border, so they cut the stroke
        // rather than the graph above.
        .padding(.top, Theme.borderLabelHeight / 2)
    }

    /// The tab strip, mounted on the editor block's own border.
    ///
    /// A tab belongs on its container's edge, not inside it. In the window
    /// header it was a window's height from the thing it changed, and every
    /// reach for it went to the editor first; in the block's heading row it was
    /// worse — a control that replaces its own container while sitting in it,
    /// which reads as a filter over the contents rather than a choice of
    /// contents. On the border it is what it is, and it doubles as the block's
    /// title, so "Graphic" stops competing with a heading that said "Band
    /// Levels" about the same thing.
    private var editorTabs: some View {
        Picker("Editor", selection: $tab) {
            Text("Graphic").tag(EditorTab.graphic)
            Text("Parametric").tag(EditorTab.parametric)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Editor")
    }

    /// The switch for whichever half is showing — the ladder on the Graphic tab,
    /// the added bands on the Parametric one. On the same border as the tab that
    /// names them, so what it governs is never in doubt.
    private var editorPower: some View {
        Toggle("", isOn: tab == .graphic ? bandsEnabled : freeFiltersEnabled)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(!audioEngine.isEnabled)
            .accessibilityLabel(tab == .graphic ? "Band levels" : "Parametric bands")
            .help(
                tab == .graphic
                    ? "Switch the band levels off to hear the parametric bands on their own"
                    : "Switch the parametric bands off to hear the band levels on their own"
            )
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

    private var freeFiltersEnabled: Binding<Bool> {
        Binding(
            get: { profileManager.areFreeFiltersEnabled },
            set: { profileManager.setFreeFiltersEnabled($0) }
        )
    }
}
