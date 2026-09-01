import Foundation

/// The report a user can copy out of Settings and paste into an issue.
///
/// Every audio defect found in CoreEQ so far has been the engine assuming
/// something a device disagreed with, with nothing anywhere saying so — and the
/// people who hit them are running a downloaded app, not a source checkout, so
/// asking them to run a command line tool was never going to work. This puts the
/// same facts one button press away from anyone who can open Settings.
///
/// Formatting is separated from gathering: everything here takes plain values,
/// so the report's shape is testable without any audio hardware.
enum DiagnosticsReport {

    /// One output device, as the report shows it.
    struct Device: Equatable {
        var name: String
        var uid: String
        var transport: String
        var isAggregate: Bool
        var isDefaultOutput: Bool
        /// Channels per buffer, in the shape `EQProcessor.render` receives.
        var bufferChannels: [Int]
        /// Channels per output stream.
        var streamChannels: [Int]
        var preferredStereo: StereoPair?
        /// Zero-based channels the device calls LFE. Empty means it reports no
        /// layout — not that it has no LFE.
        var lfeChannels: [Int] = []
    }

    /// What the running engine actually settled on, as opposed to what a device
    /// says it can do. This is the half a command line tool cannot report: it
    /// would have to build its own tap and infer.
    struct Engine: Equatable {
        var status: String
        var deviceName: String
        var sampleRate: Double
        var tapChannels: Int
        var isDeviceBound: Bool
        var boundStream: Int
        /// Output channel each tap channel is written to.
        var destinations: [Int]
        var aggregateChannels: Int
        /// Input buffer the tap was read from. Nonzero means the output device
        /// is duplex and contributes input buffers ahead of the tap's.
        var tapBufferIndex: Int = 0
        /// Tap channels the render path will actually carry, when that is fewer
        /// than the map names. The map is built from the device; the processor
        /// has a fixed ceiling. Reporting the map alone would name destinations
        /// no audio ever reaches — nil when nothing is known to be dropped.
        var routedChannels: Int?
        /// Taps the engine created. More than one means the device presents its
        /// channels as several streams and each needed its own tap.
        var tapCount: Int = 1
        /// Whether the tap has delivered anything but silence since the engine
        /// started.
        ///
        /// The one fact that separates "nothing is playing" from "nothing is
        /// reaching us", and it cannot be worked out from outside the render
        /// loop. Reported rather than acted on: a Mac that is simply quiet looks
        /// identical from here, so this is for a reader to weigh, not for the
        /// app to conclude from.
        var hasReceivedAudio: Bool = false
        /// Whether the tap is muting other processes yet. It does not until the
        /// engine has seen it deliver audio, so an unmuted tap means CoreEQ is
        /// still proving it can capture — or has concluded that it cannot.
        var isMuting: Bool = false
        /// The widest interval, if any, in which the filters ran at a rate the
        /// device was not using.
        ///
        /// Measured rather than assumed to be zero. On the hardware tested there
        /// is no such interval — Core Audio stops the device across a rate
        /// change, and the new rate is staged long before audio resumes — but
        /// that rests on a behaviour rather than a documented promise. A machine
        /// where it does not hold would sound like every band moving during a
        /// call, and nothing else in this report would show it.
        var rateWindow: RateWindow.Measurement?
    }

    /// How the saved EQ is keyed, which is the fact that settles "my preset did
    /// not come back". A device's state is filed under its persistent UID, so a
    /// state that went to the wrong slot — or to the no-device slot — is
    /// invisible from the UI but obvious here.
    struct Profiles: Equatable {
        /// UID of the output the app is currently filing state under.
        var currentDeviceUID: String?
        /// Every slot that holds saved state, so a mismatch is visible.
        var savedSlots: [String]
        /// Preset name in the slot the app is filing under.
        var storedProfileName: String?
        /// A/B slot recorded in that stored state.
        var storedSlot: String?
        /// Preset name the manager actually has in memory.
        var liveProfileName: String?
        /// A/B slot the manager actually has in memory.
        var liveSlot: String?
        /// What the device list last reported, and how many reports it has made.
        var deviceListUID: String?
        var deviceListUpdates: Int = 0
        /// What the system says the default output is, right now.
        var systemDeviceUID: String?

        /// Whether what is on screen disagrees with what is filed. The whole
        /// reason both halves are reported.
        var isConsistent: Bool {
            (storedProfileName == liveProfileName) && (storedSlot == liveSlot)
        }
    }

    static func text(
        appVersion: String,
        systemVersion: String,
        permission: TapAccess,
        devices: [Device],
        engine: Engine?,
        profiles: Profiles? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("CoreEQ \(appVersion) on macOS \(systemVersion)")
        // Above the engine section, because it is the first question any audio
        // problem raises and it is true whether or not the engine is running.
        lines.append("System audio permission: \(permission.reportDescription)")
        lines.append("")

        lines.append("Engine")
        if let engine {
            lines.append("  status:          \(engine.status)")
            lines.append("  device:          \(engine.deviceName)")
            lines.append("  sample rate:     \(Int(engine.sampleRate)) Hz")
            lines.append(
                "  tap:             \(engine.tapChannels) channel(s), "
                    + (engine.isDeviceBound
                        ? (engine.tapCount > 1
                            ? "device-bound, one tap on each of \(engine.tapCount) streams"
                            : "device-bound on stream \(engine.boundStream)")
                        : "stereo mixdown (fallback)"))
            if !engine.isDeviceBound {
                lines.append(
                    "                   NOTE: audio is mixed to stereo before CoreEQ sees it.")
            }
            lines.append("  aggregate:       \(engine.aggregateChannels) output channel(s)")
            lines.append("  tap buffer:      input buffer \(engine.tapBufferIndex)")
            lines.append(
                "  channel map:     "
                    + describeMap(engine.destinations, routed: engine.routedChannels))
            lines.append(
                "  capturing:       "
                    + (engine.hasReceivedAudio
                        ? "yes" : "no audio seen since the engine started"))
            lines.append(
                "  muting others:   "
                    + (engine.isMuting
                        ? "yes" : "no — not proven able to capture, so audio is left alone"))
            if let window = engine.rateWindow {
                lines.append(
                    String(
                        format:
                            "  rate window:     %.0f ms at %.0f Hz while the device ran at %.0f Hz",
                        window.seconds * 1_000, window.configuredRate, window.observedRate))
                lines.append(
                    String(
                        format:
                            "                   NOTE: for that long every band was displaced; "
                            + "a 1 kHz band sat at %.0f Hz.",
                        window.displacedKilohertzBand))
            } else {
                lines.append("  rate window:     none seen")
            }
            if let routed = engine.routedChannels, engine.destinations.count > routed {
                lines.append(
                    "                   NOTE: this device presents more channels than CoreEQ "
                        + "renders; the rest are silent.")
            }
        } else {
            lines.append("  not running")
        }
        lines.append("")

        if let profiles {
            lines.append("Profiles")
            lines.append("  filing under:    \(profiles.currentDeviceUID ?? "(no device)")")
            lines.append(
                "  on screen:       \(profiles.liveProfileName ?? "unknown"), "
                    + "slot \(profiles.liveSlot ?? "?")")
            lines.append(
                "  filed:           \(profiles.storedProfileName ?? "nothing"), "
                    + "slot \(profiles.storedSlot ?? "?")")
            lines.append(
                "  device list saw:  \(profiles.deviceListUID ?? "(none)") "
                    + "after \(profiles.deviceListUpdates) update(s)")
            lines.append("  system says:     \(profiles.systemDeviceUID ?? "(none)")")
            if profiles.deviceListUID != profiles.systemDeviceUID {
                lines.append(
                    "                   STALE: the device list has not seen the current output.")
            } else if profiles.currentDeviceUID != profiles.systemDeviceUID {
                lines.append(
                    "                   NOT FOLLOWED: the list saw the change, the EQ did not.")
            }
            if !profiles.isConsistent {
                lines.append(
                    "                   MISMATCH: the screen and the saved state disagree.")
            }
            if profiles.savedSlots.isEmpty {
                lines.append("  saved slots:     none")
            } else {
                for slot in profiles.savedSlots {
                    lines.append("  saved slot:      \(slot.isEmpty ? "(no device)" : slot)")
                }
            }
            lines.append("")
        }

        lines.append("Output devices")
        for device in devices {
            lines.append("")
            lines.append("  \(device.name)\(device.isDefaultOutput ? "   <- system default" : "")")
            lines.append("    uid:           \(device.uid)")
            lines.append("    transport:     \(device.transport)")
            lines.append(
                "    buffers:       \(device.bufferChannels.count) "
                    + "[\(device.bufferChannels.map(String.init).joined(separator: " + "))], "
                    + "\(device.bufferChannels.reduce(0, +)) channels")
            lines.append(
                "    streams:       \(device.streamChannels.count) "
                    + "[\(device.streamChannels.map { "\($0)ch" }.joined(separator: ", "))]")
            if let pair = device.preferredStereo {
                lines.append("    stereo pair:   channels \(pair.left) and \(pair.right)")
            } else {
                lines.append("    stereo pair:   not reported")
            }
            lines.append(
                "    LFE:           "
                    + (device.lfeChannels.isEmpty
                        ? "no layout reported"
                        : "channel(s) \(device.lfeChannels.map(String.init).joined(separator: ", "))")
            )
            if device.isAggregate {
                lines.append(
                    "    NOTE: Aggregate or Multi-Output Device. CoreEQ cannot render "
                        + "through one.")
            }
        }
        if devices.isEmpty {
            lines.append("  none found")
        }

        return lines.joined(separator: "\n")
    }

    /// "tap 0 → 0, tap 1 → 1", or a note when a channel goes nowhere.
    ///
    /// `routed` is how many of them the render path actually carries. Channels
    /// past it are named as dropped rather than as destinations, because that is
    /// what happens to them.
    private static func describeMap(_ destinations: [Int], routed: Int? = nil) -> String {
        guard !destinations.isEmpty else { return "empty" }
        let limit = routed ?? destinations.count
        return destinations.enumerated()
            .map { index, destination in
                if index >= limit { return "tap \(index) → dropped (channel limit)" }
                return destination < 0 ? "tap \(index) → dropped" : "tap \(index) → \(destination)"
            }
            .joined(separator: ", ")
    }
}
