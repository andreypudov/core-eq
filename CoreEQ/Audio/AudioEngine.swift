import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os

/// Owns the system-wide audio path.
///
/// CoreEQ intercepts system audio with a Core Audio process tap (macOS 14.2+):
/// a global tap with `muteBehavior = .mutedWhenTapped` silences every other
/// process's output at the hardware while delivering their mixed audio to us.
/// The tap and the current default output device are combined into a private
/// aggregate device, and an IO proc on that aggregate reads the tapped audio,
/// runs it through `EQProcessor`, and writes it back out — so the only audio
/// reaching the speakers is the equalized signal.
///
/// The engine rebuilds itself when the default output device changes, when the
/// sample rate changes, and after wake from sleep.
@MainActor
final class AudioEngine: ObservableObject {
    enum Status: Equatable {
        case stopped
        case running(deviceName: String)
        /// `summary` is a few words, for surfaces that cannot afford a sentence
        /// — a menu is as wide as its widest item. `message` says what to
        /// change, and is what every surface with room for it shows.
        case failed(summary: String, message: String)

        var description: String {
            switch self {
            case .stopped:
                return "Audio engine stopped."
            case .running(let deviceName):
                return "Processing system audio on “\(deviceName)”."
            case .failed(_, let message):
                return "Audio engine error: \(message)"
            }
        }
    }

    @Published private(set) var status: Status = .stopped

    @Published private(set) var tapAccess: TapAccess = .unknown

    /// Rate assumed before a device has reported one. Only ever seen during
    /// launch, and replaced as soon as the aggregate device exists.
    static let defaultSampleRate = 44_100.0

    /// Nominal sample rate of the active aggregate device. The response curve
    /// uses it so the drawn filters match what the processor actually renders.
    @Published private(set) var sampleRate = AudioEngine.defaultSampleRate

    /// What the engine actually settled on, for the diagnostics report.
    ///
    /// Published rather than queried because the Settings window is a separate
    /// scene that cannot reach the engine, and because these are decisions
    /// rather than device facts — nothing outside the engine can rediscover
    /// which tap it got or where it decided to put the channels.
    @Published private(set) var diagnostics: DiagnosticsReport.Engine?

    /// Whether the EQ is actually shaping audio: switched on *and* running.
    ///
    /// The one question the UI should ask about appearance. "Switched off" and
    /// "cannot run on this device" differ in how they are fixed, not in what
    /// they mean for the sound, so a control drawn at full strength in either
    /// case claims something untrue. Deriving this rather than forcing
    /// `isEnabled` off keeps the two apart where they do differ: the switch
    /// still holds what the user asked for, and asking for it back is still the
    /// way out.
    var isProcessing: Bool {
        guard isEnabled else { return false }
        if case .running = status { return true }
        return false
    }

    /// Whether asking for the equalizer to be on can achieve anything.
    ///
    /// False while the engine cannot run at all — an output device it has to
    /// refuse, say. Switching on then changes a stored preference and nothing
    /// else, so the switch is disabled rather than left to report a state the
    /// sound does not have.
    var canProcess: Bool {
        if case .failed = status { return false }
        return true
    }

    /// Global bypass. When false the engine keeps running but passes audio
    /// through untouched, so toggling is instant and glitch-free.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            processor.setBypassed(!isEnabled)
            settings.isEnabled = isEnabled
        }
    }

    /// Live spectrum of the played-back audio, driving the response plot's
    /// backdrop. Fed by `processor` from the render thread.
    let spectrum: SpectrumAnalyzer

    private let processor = EQProcessor()
    private let settings: SettingsStore
    private let logger = Logger(subsystem: "com.andreypudov.coreeq", category: "AudioEngine")

    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var streamConfigListener: AudioObjectPropertyListenerBlock?
    private var wakeObserver: (any NSObjectProtocol)?
    private var pendingRestart: DispatchWorkItem?
    private var retryCount = 0

    private static let maxRetries = 3

    init(settings: SettingsStore) {
        self.settings = settings
        self.isEnabled = settings.isEnabled
        // Two steps because the provider closes over `self`: the analyzer has to
        // exist before there is a `self` to hand it.
        self.spectrum = SpectrumAnalyzer(
            buffer: processor.spectrumBuffer,
            sampleRate: { AudioEngine.defaultSampleRate }
        )
        processor.setBypassed(!settings.isEnabled)
        spectrum.setSampleRateProvider { [weak self] in
            self?.sampleRate ?? AudioEngine.defaultSampleRate
        }
    }

    // MARK: - Lifecycle

    func start() {
        pendingRestart?.cancel()
        // Before the attempt, not after it. These two outlive any single
        // aggregate device — that is the point of them — and installing them at
        // the end of `startEngine` meant a start that threw never installed
        // them at all. Refusing an unsupported output device does throw, and
        // deliberately does not retry, so the engine was left with no way to
        // learn that the user had switched to a device it could serve: the
        // failure was permanent in the strong sense, until the app was
        // relaunched. Installed here, a device change always gets a hearing.
        installDefaultDeviceListenerIfNeeded()
        installWakeObserverIfNeeded()
        do {
            try startEngine()
            retryCount = 0
        } catch {
            teardownEngine()
            let message =
                (error as? CoreAudioError)?.localizedDescription ?? error.localizedDescription
            logger.error("Engine start failed: \(message, privacy: .public)")
            diagnostics = nil
            if error is TapUnavailable { tapAccess = .denied }
            status = .failed(summary: Self.summary(for: error), message: message)
            let isPermanent = (error as? UnusableOutputDevice)?.isPermanent ?? false
            if !isPermanent, retryCount < Self.maxRetries {
                retryCount += 1
                scheduleRestart(after: 3.0, reason: "retry \(retryCount) after failure")
            }
        }
    }

    /// Stops for good, as opposed to the teardown a restart does.
    ///
    /// The system observers have to come off here. They outlive any single
    /// aggregate device — that is the point of them — so left installed they
    /// would answer the next device change or wake by starting an engine the app
    /// has already shut down, which on quit means building a tap during
    /// termination.
    func stop() {
        pendingRestart?.cancel()
        removeSystemObservers()
        teardownEngine()
        diagnostics = nil
        status = .stopped
    }

    func apply(filters: [EQFilter]) {
        processor.setFilters(filters)
    }

    func apply(preamp: Double) {
        processor.setPreamp(preamp)
    }

    // MARK: - Engine assembly

    private func startEngine() throws {
        teardownEngine()

        let outputID = try defaultOutputDeviceID()
        let outputUID = try deviceUID(of: outputID)
        let outputName = (try? deviceName(of: outputID)) ?? "Unknown Device"

        // Core Audio will not nest one aggregate device inside another, and it
        // does not say so. Handed an Aggregate or Multi-Output Device as a
        // sub-device, `AudioHardwareCreateAggregateDevice` still returns noErr —
        // it silently drops the sub-device, leaving an aggregate with no active
        // sub-devices and no output streams at all. `AudioDeviceStart` then
        // succeeds on that empty device and the IO proc runs normally, handed
        // real tapped audio and an output buffer list with zero buffers, so
        // `EQProcessor.render` writes nowhere and every stage no-ops in silence.
        //
        // Meanwhile the tap goes on muting every other process at the hardware.
        // The result is a completely silent Mac while the app reports that it is
        // working, and bypass does not rescue it because bypass does not release
        // the tap. Refusing here — before the tap exists — is what keeps a
        // configuration CoreEQ cannot serve from taking the machine's audio down
        // with it.
        guard !AudioDevices.isAggregate(outputID) else {
            throw UnusableOutputDevice.aggregateDevice(name: outputName)
        }

        // Tap every process except our own output, otherwise the equalized
        // signal we play back would be captured again as a feedback loop.
        var excluded: [AudioObjectID] = []
        if let selfObject = try? processObjectID(for: getpid()) {
            excluded.append(selfObject)
        }
        let taps = try makeTaps(excluding: excluded, outputUID: outputUID, outputID: outputID)
        tapIDs = taps.map(\.id)
        let tap = taps[0]

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CoreEQ Aggregate",
            kAudioAggregateDeviceUIDKey:
                "\(AudioDevices.coreEQAggregateUIDPrefix)\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            // One entry per tap. A device presenting several output streams
            // needs one tap each, and the aggregate carries them all.
            kAudioAggregateDeviceTapListKey: taps.map { tap in
                [
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            },
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID),
            "creating the aggregate device")
        aggregateID = newAggregateID

        // The guard above covers the one cause of this we know of. This is the
        // invariant itself: an aggregate reporting success is not evidence that
        // it has anywhere to put audio, and running an IO proc against one that
        // does not is indistinguishable from working, from the inside.
        guard AudioDevices.hasOutputChannels(aggregateID) else {
            throw UnusableOutputDevice.noOutputStreams(name: outputName)
        }

        let rate = try nominalSampleRate(of: aggregateID)
        processor.setSampleRate(rate)
        sampleRate = rate

        // Tell the processor what this device actually looks like, so the render
        // thread never has to guess.
        let inputBuffers = AudioDevices.inputBufferChannels(of: outputID).count
        let layout: EQProcessor.OutputLayout
        if taps.count > 1 {
            layout = OutputPlan.layout(
                forTaps: taps.map {
                    OutputPlan.TapPlan(channels: $0.channels, firstOutputChannel: $0.firstChannel)
                },
                inputBuffers: inputBuffers)
        } else {
            layout = OutputPlan.layout(
                for: DeviceDescription(
                    tapChannels: tap.channels,
                    isDeviceBound: tap.isDeviceBound,
                    deviceChannels: AudioDevices.outputChannelCount(of: outputID),
                    preferredStereo: AudioDevices.preferredStereoPair(of: outputID),
                    inputBuffers: inputBuffers))
        }
        processor.setOutputLayout(layout)

        let processor = self.processor
        var newProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(
                &newProcID, aggregateID, nil, Self.ioBlock(for: processor)),
            "creating the IO proc")
        ioProcID = newProcID

        try check(AudioDeviceStart(aggregateID, newProcID), "starting the aggregate device")

        // Only the two tied to this aggregate. The device and wake observers
        // are installed by `start()`, so that they exist even when this throws.
        installSampleRateListener()
        installStreamConfigurationListener()

        diagnostics = DiagnosticsReport.Engine(
            status: "running",
            deviceName: outputName,
            sampleRate: rate,
            tapChannels: layout.tapChannels,
            isDeviceBound: tap.isDeviceBound,
            boundStream: tap.stream,
            destinations: layout.destinations,
            aggregateChannels: AudioDevices.outputChannelCount(of: aggregateID),
            tapBufferIndex: layout.tapBufferIndex,
            routedChannels: min(layout.tapChannels, EQProcessor.maxChannels),
            tapCount: taps.count
        )

        status = .running(deviceName: outputName)
        logger.info("Engine running on \(outputName, privacy: .public)")
    }

    /// The block Core Audio calls on its realtime IO thread.
    ///
    /// `nonisolated`, and a separate function, for one reason: a closure written
    /// inline in `startEngine` is formed inside a `@MainActor` type and inherits
    /// that isolation, so the compiler emits an executor check at every call.
    /// Core Audio then calls it from `com.apple.audio.IOThread.client`, the
    /// check fails, and `dispatch_assert_queue` traps the process the moment
    /// audio starts flowing. Swift 5 emitted no such check, which is why this
    /// only became a crash on the move to Swift 6 — the code had always been
    /// wrong about which thread it runs on, and the language started saying so.
    ///
    /// Building it here, outside the actor, is what makes it nonisolated. It
    /// cannot be fixed by marking the inline closure `@Sendable`: that was
    /// tried, it compiles, and it still traps.
    private nonisolated static func ioBlock(for processor: EQProcessor) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            processor.render(input: input, output: output)
        }
    }

    private func teardownEngine() {
        if let sampleRateListener, aggregateID != kAudioObjectUnknown {
            var addr = propertyAddress(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, .main, sampleRateListener)
        }
        sampleRateListener = nil

        if let streamConfigListener, aggregateID != kAudioObjectUnknown {
            var addr = propertyAddress(
                kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, .main, streamConfigListener)
        }
        streamConfigListener = nil

        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        for tap in tapIDs where tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
        }
        tapIDs = []
    }

    // MARK: - Change handling

    /// Removes the observers that survive a restart. `start()` reinstalls both,
    /// so stopping and starting again is a complete cycle.
    private func removeSystemObservers() {
        if let defaultDeviceListener {
            var addr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, .main, defaultDeviceListener
            )
        }
        defaultDeviceListener = nil

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    private func scheduleRestart(after delay: TimeInterval, reason: String) {
        logger.info("Restart scheduled: \(reason, privacy: .public)")
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Rebuilds when the device changes the shape of its output.
    ///
    /// The channel map is worked out once, at start, from the stream
    /// configuration as it was then. A device that renegotiates afterwards
    /// leaves the map describing a layout that no longer exists, and the audio
    /// goes to the wrong channels or nowhere. That is a candidate explanation
    /// for the report of an interface that plays "for a split second and then
    /// it's gone" — audio starts correct and the device then changes under it.
    ///
    /// A rebuild rather than a recomputed map: a device changing its channel
    /// count invalidates the aggregate built around it, not just the map.
    private func installStreamConfigurationListener() {
        var addr = propertyAddress(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        let deviceID = aggregateID
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.aggregateID == deviceID else { return }
                self.scheduleRestart(after: 0.3, reason: "output stream configuration changed")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &addr, .main, block)
        if status == noErr {
            streamConfigListener = block
        } else {
            logger.error("Failed to install stream configuration listener: \(status)")
        }
    }

    private func installDefaultDeviceListenerIfNeeded() {
        guard defaultDeviceListener == nil else { return }
        var addr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A different device is a fresh situation: whatever the previous
                // one exhausted in retries says nothing about this one.
                self.retryCount = 0
                self.scheduleRestart(after: 0.5, reason: "default output device changed")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        if status == noErr {
            defaultDeviceListener = block
        } else {
            logger.error("Failed to install default device listener: \(status)")
        }
    }

    private func installSampleRateListener() {
        var addr = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        let deviceID = aggregateID
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.aggregateID == deviceID else { return }
                if let rate = try? self.nominalSampleRate(of: deviceID) {
                    self.processor.setSampleRate(rate)
                    self.sampleRate = rate
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &addr, .main, block)
        if status == noErr {
            sampleRateListener = block
        } else {
            logger.error("Failed to install sample rate listener: \(status)")
        }
    }

    private func installWakeObserverIfNeeded() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.scheduleRestart(after: 1.0, reason: "system woke from sleep")
            }
        }
    }

    // MARK: - Core Audio property helpers

    /// The tap could not be created.
    ///
    /// Its own type because it is the one failure that means the permission was
    /// refused, and the only one the Settings pane may describe that way.
    private struct TapUnavailable: Error, LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            "CoreEQ could not capture system audio (OSStatus \(status)). Check that "
                + "System Audio Recording is allowed in Privacy & Security."
        }
    }

    /// A default output device the engine cannot render through.
    ///
    /// Separate from `CoreAudioError` because nothing here is a failed Core
    /// Audio call. Every call succeeds; these are the cases where what comes
    /// back reports success and is nonetheless unusable.
    private enum UnusableOutputDevice: Error, LocalizedError {
        case aggregateDevice(name: String)
        case noOutputStreams(name: String)

        /// Whether trying again could produce a different answer. Nesting never
        /// will, so retrying only republishes the same failure three more times
        /// and leaves the user watching a status message flap. An empty
        /// aggregate from some cause we have not identified might be transient,
        /// so that one keeps the retries.
        var isPermanent: Bool {
            switch self {
            case .aggregateDevice: return true
            case .noOutputStreams: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .aggregateDevice(let name):
                return """
                    “\(name)” is an Aggregate or Multi-Output Device, which CoreEQ \
                    cannot process audio through. Choose a single output device.
                    """
            case .noOutputStreams(let name):
                return """
                    The audio device CoreEQ built around “\(name)” reported no output \
                    channels, so there is nowhere to send the equalized audio.
                    """
            }
        }
    }

    /// A tap whose samples are not the Float32 the render path assumes.
    ///
    /// Its own type so the device-bound attempt can fall back to the stereo
    /// global tap on it, the same way it falls back on a tap that could not be
    /// created at all.
    private struct UnrenderableTapFormat: Error, LocalizedError {
        var errorDescription: String? {
            "The audio tap did not deliver 32-bit float samples, which is the "
                + "only format CoreEQ renders."
        }
    }

    private struct CoreAudioError: Error, LocalizedError {
        let status: OSStatus
        let operation: String

        var errorDescription: String? { "\(operation) failed (OSStatus \(status))" }
    }

    /// A few words naming what went wrong, for the menu.
    private static func summary(for error: any Error) -> String {
        switch error {
        case is UnusableOutputDevice: return "Unsupported output device"
        case is TapUnavailable: return "System audio not allowed"
        default: return "Audio engine error"
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
    }

    private func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func defaultOutputDeviceID() throws -> AudioDeviceID {
        var addr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID),
            "reading the default output device"
        )
        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioError(
                status: OSStatus(kAudioHardwareBadDeviceError),
                operation: "reading the default output device")
        }
        return deviceID
    }

    private func deviceUID(of deviceID: AudioDeviceID) throws -> String {
        var addr = propertyAddress(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid),
            "reading the device UID")
        return uid?.takeRetainedValue() as String? ?? ""
    }

    private func deviceName(of deviceID: AudioDeviceID) throws -> String {
        var addr = propertyAddress(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name),
            "reading the device name")
        return name?.takeRetainedValue() as String? ?? ""
    }

    /// The system audio tap, and what it will deliver.
    private struct Tap {
        let id: AudioObjectID
        let uuid: UUID
        let channels: Int
        /// Output stream it was bound to, or -1 for the stereo global tap.
        let stream: Int
        /// Whether this is the device- and stream-bound tap, whose format
        /// matches the device's, rather than the stereo mixdown.
        let isDeviceBound: Bool
        /// Global output channel this tap's channel 0 feeds. Zero for a single
        /// tap; the running total of earlier streams when there are several.
        var firstChannel: Int = 0
    }

    /// Creates the tap, preferring the one that does not mix the audio down.
    ///
    /// A tap bound to the output device's stream takes the format of that
    /// stream, so a device presenting eight channels is captured as eight. The
    /// stereo global tap — what CoreEQ has always used — instead delivers a two
    /// channel mixdown, which on a surround device means the surround content is
    /// gone and, because the tap mutes the original at the hardware, gone
    /// irrecoverably while CoreEQ runs.
    ///
    /// The device-bound form binds the tap to one device and stream, which is
    /// newer ground and a per-device failure mode CoreEQ has never had. So it is
    /// attempted and not required: a device it cannot serve degrades to the
    /// stereo behaviour that already worked rather than to no audio at all.
    private func makeTaps(
        excluding excluded: [AudioObjectID], outputUID: String, outputID: AudioDeviceID
    ) throws -> [Tap] {
        let numbers = excluded.map(NSNumber.init(value:))
        let streams = AudioDevices.outputStreamChannelCounts(of: outputID)

        // A tap binds to one stream and takes that stream's format, so a device
        // presenting its channels as several streams needs one tap each. Binding
        // to the widest alone captured that stream and abandoned the rest, which
        // on an interface presenting eight stereo streams is fourteen of sixteen
        // channels.
        if streams.count > 1, streams.allSatisfy({ $0 > 0 }) {
            var taps: [Tap] = []
            var offset = 0
            for (index, channels) in streams.enumerated() {
                guard
                    let tap = try? makeTap(
                        CATapDescription(
                            __excludingProcesses: numbers, andDeviceUID: outputUID,
                            withStream: index),
                        isDeviceBound: true, stream: index)
                else { break }
                taps.append(
                    Tap(
                        id: tap.id, uuid: tap.uuid, channels: tap.channels, stream: tap.stream,
                        isDeviceBound: true, firstChannel: offset))
                offset += channels
            }
            if taps.count == streams.count {
                logger.info(
                    """
                    Device-bound taps: \(taps.count, privacy: .public) streams, \
                    \(offset, privacy: .public) channels
                    """)
                return taps
            }
            // Partial success is not a usable device: the streams that did tap
            // would be muted and replaced while the rest played on untouched.
            for tap in taps { AudioHardwareDestroyProcessTap(tap.id) }
            logger.info("Per-stream taps incomplete; falling back")
        }

        let stream = OutputPlan.widestStream(of: streams)
        if let tap = try? makeTap(
            CATapDescription(
                __excludingProcesses: numbers, andDeviceUID: outputUID, withStream: stream),
            isDeviceBound: true, stream: stream)
        {
            logger.info("Device-bound tap: \(tap.channels, privacy: .public) channels")
            return [tap]
        }

        logger.info("Device-bound tap unavailable; using the stereo global tap")
        return [
            try makeTap(
                CATapDescription(stereoGlobalTapButExcludeProcesses: excluded),
                isDeviceBound: false, stream: -1)
        ]
    }

    private func makeTap(
        _ description: CATapDescription, isDeviceBound: Bool, stream: Int
    ) throws -> Tap {
        description.name = "CoreEQ System Tap"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else { throw TapUnavailable(status: status) }
        tapAccess = .granted
        let format = tapFormat(of: id)
        // A tap the render path cannot read is worse than no tap: it would mute
        // every other process and play the reinterpreted bytes. Destroy it and
        // let the caller fall back.
        guard format.isRenderable else {
            AudioHardwareDestroyProcessTap(id)
            throw UnrenderableTapFormat()
        }
        return Tap(
            id: id, uuid: description.uuid, channels: format.channels,
            stream: stream, isDeviceBound: isDeviceBound)
    }

    /// What the tap will deliver, read from the tap's own format rather than
    /// assumed from what we asked for.
    ///
    /// The format matters as much as the channel count. `EQProcessor.render`
    /// binds the tap's bytes to `Float` and does arithmetic on them, so a tap
    /// carrying anything else would not fail — it would reinterpret the
    /// samples and render noise. A device-bound tap takes *the stream's*
    /// format, which is the device's to choose, so this is checked rather than
    /// trusted.
    private func tapFormat(of tap: AudioObjectID) -> (channels: Int, isRenderable: Bool) {
        var addr = propertyAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format) == noErr,
            format.mChannelsPerFrame > 0
        else {
            return (EQProcessor.OutputLayout().tapChannels, false)
        }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        return (Int(format.mChannelsPerFrame), isFloat && format.mBitsPerChannel == 32)
    }

    private func nominalSampleRate(of deviceID: AudioDeviceID) throws -> Double {
        var addr = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate),
            "reading the sample rate")
        return rate
    }

    private func processObjectID(for pid: pid_t) throws -> AudioObjectID {
        var addr = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &objectID
            ),
            "translating our PID to an audio process object"
        )
        return objectID
    }
}
