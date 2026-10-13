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

    /// What the A/B control is showing. Mirrors `ProfileManager.abSlot` rather
    /// than reading it directly — see `abSwitcher` for why.
    @State private var selectedSlot: ABSlot = .a

    /// Which editor the lower area is showing. Remembered across launches.
    ///
    /// A tab changes the controls and nothing else: the preset, the chain, the
    /// graph, and the audio are identical either side of a switch. The editing
    /// area is a fixed height for the same reason — nothing above it moves.
    @AppStorage("editorTab") private var tab: EditorTab = .graphic

    @State private var isPiPVisible = false

    enum EditorTab: String {
        case graphic, parametric
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            header

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
            .opacity(audioEngine.isProcessing ? 1.0 : 0.5)
            .allowsHitTesting(audioEngine.isProcessing)
            .help("Point at a handle to read its value; drag it to adjust; double-click to reset it")

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
        .onDisappear {
            // Do not stop the analyzer if PiP is visible: PiP owns the analyzer
            // lifecycle while it is shown so the visualization remains live.
            if !PiPWindowManager.shared.isVisible {
                spectrum.stop()
            }
        }
    }

    // MARK: - Header

    /// The editor switcher, where the sound is going, a way back to the saved
    /// preset, and the master switch.
    ///
    /// No "Equalizer" title and no preset pop-up: the window is the equalizer,
    /// and the sidebar already lists every preset with the active one ticked.
    /// Naming both again here was furniture.
    private var header: some View {
        // Three columns: the comparison switch, the device with the preset
        // playing on it and the way back to that preset, and the app's own
        // controls. The centre keeps the column's centreline by giving the two
        // sides equal, flexible halves — *not* by floating over them, which is
        // what let the engine warning slide underneath the pop-up and collide
        // with its chevron. Laid out in the row, the sides can only push and
        // truncate, never overlap.
        HStack(spacing: 12) {
            abSwitcher
                .frame(maxWidth: .infinity, alignment: .leading)

            deviceAndRevert

            HStack(spacing: 10) {
                // The symbol alone, with the sentence in its tooltip. A rare
                // state should not hold a phrase's worth of the row open at
                // every other moment — and at the window's minimum width, that
                // phrase is what would push the preset out of the header.
                if let warning = engineWarning, engineFailure == nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                        .help(audioEngine.status.description)
                        .accessibilityLabel(warning)
                }

                settingsButton

                Button {
                    isPiPVisible.toggle()
                    if isPiPVisible {
                        PiPWindowManager.shared.show(analyzer: spectrum)
                    } else {
                        PiPWindowManager.shared.hide()
                    }
                } label: {
                    Image(systemName: isPiPVisible ? "pip.exit" : "pip")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isPiPVisible ? "Close Picture-in-Picture" : "Open Picture-in-Picture")
                .accessibilityLabel("Picture-in-Picture")

                // Furthest right, and unlabelled: it governs everything in the
                // window, so it belongs at the end of the row rather than inside
                // any one section. Deliberately not dimmed with the rest when
                // off — it is the way back on.
                //
                // When the engine cannot run at all it is dimmed, because then
                // it is not the way back on: the way back is a different output
                // device. Its position still shows what the user asked for, so
                // the setting is waiting rather than lost.
                Toggle("", isOn: $audioEngine.isEnabled)
                    .toggleStyle(.power)
                    .labelsHidden()
                    .disabled(!audioEngine.canProcess)
                    .opacity(audioEngine.canProcess ? 1.0 : 0.5)
                    .accessibilityLabel("Equalizer")
                    .help(
                        audioEngine.canProcess
                            ? (audioEngine.isEnabled
                                ? "Turn the equalizer off" : "Turn the equalizer on")
                            : audioEngine.status.description)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: Theme.headerHeight)
    }

    /// The device, the preset playing on it, and the way back to that preset as
    /// it was saved.
    ///
    /// Revert sits here rather than at the end of the row because this is where
    /// its object is named. It used to be an inch away from the gear and the
    /// power button, with nothing beside it saying what it would undo.
    ///
    /// The empty cell on the left is the same width as the button on the right,
    /// so the device control stays on the column's centreline whether or not
    /// there is anything to revert — otherwise it would slide sideways by half a
    /// button the moment a slider was touched.
    private var deviceAndRevert: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: Theme.revertSlotWidth, height: 1)
                .accessibilityHidden(true)

            deviceControl

            Button("Revert") { profileManager.resetToActiveProfile() }
                .controlSize(.small)
                .frame(width: Theme.revertSlotWidth, alignment: .leading)
                .help("Discard changes and return to the saved preset")
                // Hidden rather than removed: the slot is held either way, and
                // fading keeps the row still while the button comes and goes.
                .opacity(profileManager.isModified ? 1 : 0)
                .disabled(!profileManager.isModified)
                .accessibilityHidden(!profileManager.isModified)
                .animation(.easeInOut(duration: 0.15), value: profileManager.isModified)
        }
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
            // A `Button` with a real `NSMenu`, not a SwiftUI `Menu`: see
            // `PopUpMenuButton` for what a `Menu` does to a two-line label, and
            // what happened to the click when that was worked around.
            PopUpMenuButton {
                outputMenu()
            } label: {
                deviceLines(showsChevron: true)
            }
            .frame(width: Theme.outputControlWidth)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Output device")
            .accessibilityValue(deviceAccessibilityValue)
        } else {
            // One output, or none: state it rather than offering a choice the
            // machine cannot honour.
            deviceLines(showsChevron: false)
                .frame(width: Theme.outputControlWidth)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Output device")
                .accessibilityValue(deviceAccessibilityValue)
        }
    }

    /// The outputs, with the current one ticked.
    ///
    /// One line per row. `NSMenuItem` does have a `subtitle` on macOS 14, so
    /// each device could name its own preset here — worth doing, but it needs a
    /// way to read another device's stored preset, which `ProfileManager` does
    /// not expose yet.
    private func outputMenu() -> NSMenu {
        let menu = NSMenu()
        for device in outputs.devices {
            let item = ActionMenuItem(title: device.name) { [outputs] in
                outputs.select(device.id)
            }
            item.image = NSImage(
                systemSymbolName: device.symbolName, accessibilityDescription: nil)
            item.state = device.id == outputs.defaultDeviceID ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func deviceLines(showsChevron: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: outputs.defaultDeviceSymbolName)
                .font(Theme.Font.body)
                .foregroundStyle(
                    outputs.devices.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))

            VStack(alignment: .leading, spacing: 0) {
                Text(outputs.defaultDeviceName)
                    .font(Theme.Font.body)
                    .foregroundStyle(
                        outputs.devices.isEmpty
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Text(profileManager.activeProfileName)
                        .font(Theme.Font.secondary)
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

The file continues...