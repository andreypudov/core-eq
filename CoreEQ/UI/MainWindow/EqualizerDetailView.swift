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

    enum EditorTab: String {
        case graphic, parametric
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            header

            graph
                // The same dimming as every other control, from the same rule.
                // The curve is the one that actively misleads while nothing is
                // being processed — it draws a shaped response for audio that is
                // not being shaped — so it also carries the explanation.
                .opacity(audioEngine.isProcessing ? 1.0 : 0.5)
                .overlay {
                    if case .awaitingPermission(let offer) = audioEngine.status {
                        permissionOverlay(offer)
                    } else if let failure = engineFailure {
                        engineOverlay(failure)
                    }
                }

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

            if showsChevron {
                Spacer(minLength: 4)
                // The menu's own indicator is suppressed, so the control has to
                // say it is one.
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.Font.labelEmphasized)
                    .foregroundStyle(.secondary)
            }
        }
        // The inset every button has around its title. It is what the hover
        // highlight is drawn around, and what keeps the text off the edge of the
        // target — a control whose hit area stops at its own glyphs is the thing
        // this padding exists to prevent looking like. Applied here rather than
        // in the button, so the single-device version keeps the same metrics and
        // the row does not shift when a second device appears.
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var deviceAccessibilityValue: String {
        let preset =
            profileManager.isModified
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
        .opacity(audioEngine.isProcessing ? 1.0 : 0.5)
        .allowsHitTesting(audioEngine.isProcessing)
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
                                y: Theme.BandRow.topChromeHeight
                                    + VerticalGainSlider.knobCenterY(
                                        for: 0, in: trackHeight, range: BuiltInProfiles.gainRange
                                    )
                            )
                    }
                }
            }
            .opacity(audioEngine.isProcessing ? 1.0 : 0.5)
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
                        isEnabled: audioEngine.isProcessing,
                        selectedFilterID: $selectedFilterID
                    )
                }
            }
            // Both blocks fill the row, so the Graphic and Parametric tabs and
            // the Global Gain column all read as one band of equal height.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Clears the tabs hanging into the block above this.
            .padding(.top, Theme.borderLabelClearance)
            .contentBlock()
            .borderLabel { editorTabs }

            GlobalGainView(profileManager: profileManager, isEnabled: audioEngine.isProcessing)
        }
        .frame(height: Theme.editorHeight)
        // Room for the labels hanging off the top border, so they cut the stroke
        // rather than the graph above.
        .padding(.top, Theme.borderLabelHeight / 2)
    }

    /// The way into Settings from the window.
    ///
    /// Occasional controls belong here rather than in the status menu, which
    /// should be a preset, a tone control and a way out. It sits *before* the
    /// power button: that one governs everything in the window, so it keeps the
    /// end of the row.
    private var settingsButton: some View {
        Button {
            SettingsOpener.shared.open(tab: .general)
        } label: {
            Image(systemName: "gearshape")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .help("CoreEQ settings")
    }

    /// Two working states of one preset, and the switch between them.
    ///
    /// It takes the slot the editor tabs used to hold. Both belong to the same
    /// row only in the sense that this is where the window says what you are
    /// listening to: A and B are complete sounds — preset, chain, trim, tone —
    /// so this sits beside the preset rather than inside either editor.
    ///
    /// Comparing by memory is the alternative, and auditory memory is measured
    /// in seconds.
    private var abSwitcher: some View {
        Picker("Comparison", selection: $selectedSlot) {
            Text(ABSlot.a.label).tag(ABSlot.a)
            Text(ABSlot.b.label).tag(ABSlot.b)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Comparison slot")
        .help("Two versions of this preset — switch to compare them")
        // Bound to local state and applied afterwards, rather than written
        // straight into the manager through the binding.
        //
        // A segmented picker syncs its selection while SwiftUI is updating the
        // view, so a binding whose setter swaps five published properties is
        // publishing from inside that update — which SwiftUI reports as
        // undefined behaviour, and is. `onChange` runs once the update has
        // finished, which is the only safe moment to change the model.
        //
        // The second `onChange` carries the traffic the other way: a device
        // switch loads that device's slot, and the control has to follow it.
        .onChange(of: selectedSlot) { _, slot in
            profileManager.setSlot(slot)
        }
        .onChange(of: profileManager.abSlot) { _, slot in
            selectedSlot = slot
        }
        .onAppear { selectedSlot = profileManager.abSlot }
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

    private func gainAxis(trackHeight: CGFloat) -> some View {
        GainScale(range: BuiltInProfiles.gainRange, trackHeight: trackHeight, side: .leading)
            .frame(width: Theme.axisGutter, alignment: .trailing)
            // Clears the value row, so the scale still reads against the track.
            .padding(.top, Theme.BandRow.topChromeHeight)
    }

    private func bandControl(at slot: Int, trackHeight: CGFloat) -> some View {
        // Indexed directly rather than defensively: the ladder is always
        // `bandCount` long, whatever the chain has been through — normalisation
        // on the way in from disk guarantees it, and
        // `theLadderIsNeverShortWhateverHappensToTheChain` is what would notice
        // if that ever stopped being true.
        let band = profileManager.bandFilters[slot]
        let isActive = draggingBand == slot || hoveredBand == slot

        return VStack(spacing: 6) {
            // What the slider is set to, always readable — the strip used to
            // answer this only while the pointer was on the curve above.
            //
            // The frequency's own colour, not the signal colour: these two read
            // as the pair of captions belonging to one column, and a row of
            // eleven accented numbers would out-shout the curve above that they
            // describe. Zero drops a step further back, so a flat strip stays a
            // quiet line rather than eleven numbers competing with the ones that
            // moved.
            Text(BandFormat.gain(band.gain))
                .font(Theme.Font.value)
                .foregroundStyle(
                    band.gain == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)
                )
                .frame(height: Theme.BandRow.valueHeight)
                .accessibilityHidden(true)

            VerticalGainSlider(
                value: gainBinding(at: slot),
                range: BuiltInProfiles.gainRange,
                step: 0.5,
                isEnabled: audioEngine.isProcessing,
                isActive: isActive,
                onDragChange: { isDragging in draggingBand = isDragging ? slot : nil },
                onReset: { profileManager.resetBand(at: slot) }
            )
            .frame(width: Theme.BandRow.columnWidth, height: trackHeight)
            .accessibilityLabel("\(BandFormat.frequency(band.frequency)) hertz")
            .accessibilityValue(String(format: "%+.1f decibels", band.gain))

            Text(BandFormat.frequency(band.frequency))
                .font(Theme.Font.secondary)
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
                guard audioEngine.isProcessing else { return }
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
    /// The message for a failure, or nil when the engine is running or merely
    /// stopped.
    ///
    /// Separate from `engineWarning` because the two states deserve different
    /// treatment. Stopped is benign and the symbol alone is enough. Failed means
    /// the audio is *not* being equalized and there is usually one specific
    /// thing to change — which no one will ever discover from a tooltip on a
    /// 12-point icon.
    private var engineFailure: String? {
        guard case .failed(_, let message) = audioEngine.status else { return nil }
        return message
    }

    /// What the permission is for, said before macOS asks rather than after.
    ///
    /// "System Audio Recording" sounds far broader than what an equalizer does,
    /// and the one moment that matters is the moment the system asks. Creating
    /// the tap is what raises that prompt, so the engine waits here until the
    /// button below is pressed.
    private func permissionOverlay(_ offer: AudioPermissionGate.Offer) -> some View {
        VStack(spacing: 10) {
            Label("CoreEQ needs permission to process audio", systemImage: "waveform")
                .font(Theme.Font.heading)
                .foregroundStyle(.primary)

            Text(
                "An equalizer has to reach the sound to change it. CoreEQ reads audio on its "
                    + "way to your speakers, adjusts it, and plays it straight back. Nothing is "
                    + "recorded, stored, or sent anywhere, and quitting CoreEQ hands the audio "
                    + "back immediately."
            )
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            switch offer {
            case .askTheSystem:
                Button("Allow Audio Access…") { audioEngine.requestPermission() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                Text("macOS will ask you to confirm.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
            case .openSystemSettings:
                // macOS raises its prompt once. After that only System Settings
                // can change the answer, so offering to ask again would be an
                // offer the app cannot keep.
                Button("Open System Settings…") { SettingsOpener.shared.open(tab: .general) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Text("Allow CoreEQ under Screen & System Audio Recording.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: 380)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    /// The failure, stated over the curve it invalidates.
    ///
    /// On the graph rather than above it for two reasons. The curve is what
    /// misleads while the engine is down, so the explanation belongs on the
    /// thing being contradicted. And a block inserted into the column would move
    /// the editor down every time the engine faltered, which is a layout change
    /// the size of the message — the header comment above was protecting exactly
    /// that, and an overlay costs nothing.
    ///
    /// Only the card takes clicks. The rest of the plot stays live, because an
    /// engine that cannot run is not a reason to stop someone setting up the EQ
    /// they want when it does.
    private func engineOverlay(_ message: String) -> some View {
        VStack(spacing: 8) {
            Label("Not processing audio", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.heading)
                .foregroundStyle(.primary)

            Text(message)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Details") {
                SettingsOpener.shared.open(tab: .diagnostics)
            }
            .controlSize(.small)
            .help("Open the diagnostics report")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    private var engineWarning: String? {
        switch audioEngine.status {
        case .running: return nil
        case .stopped: return "Audio engine stopped"
        case .failed: return "Audio engine error"
        case .awaitingPermission: return "Waiting for permission"
        }
    }

    // MARK: - Bindings

    private func gainBinding(at slot: Int) -> Binding<Double> {
        Binding(
            get: { profileManager.bandFilters[safe: slot]?.gain ?? 0 },
            set: { profileManager.setGain($0, forBandAt: slot) }
        )
    }

}
