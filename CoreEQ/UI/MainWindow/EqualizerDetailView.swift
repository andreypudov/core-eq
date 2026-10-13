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

            graph
                // The same dimming as every other control, from the same rule.
                // The curve is the one that actively misleads while nothing is
                // being processed — it draws a shaped response for audio that is
                // not being shaped — so it also carries the explanation.
                .opacity(audioEngine.isProcessing ? 1.0 : 0.5)
                .overlay {
                    // A permission that is missing is not a generic engine
                    // error, and wants the explanation and the one button that
                    // fixes it rather than a bare message.
                    if audioEngine.needsAudioPermission {
                        permissionOverlay
                    } else if let failure = engineFailure {
                        engineOverlay(failure)
                    } else if audioEngine.isPausedForRecording {
                        recordingOverlay
                    }
                }

            editor
        }
        .padding(.horizontal, Theme.Spacing.window)
        // The same gap the header has to the graph below it. The header sits
        // between two equal, flexible halves — *not* by floating over them, which is
        // what let the engine warning slide underneath the pop-up and collide
        // with its chevron. Laid out in the row, the sides can only push and
        // truncate, never overlap.
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
            if !PiPWindowManager.sharedIsVisible {
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

