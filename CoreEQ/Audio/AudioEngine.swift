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

    /// Builds the whole audio path, or throws having built none of it.
    ///
    /// Deliberately a sequence of named steps rather than one procedure: each
    /// one is a place the path has actually broken, and the order matters more
    /// than any individual call. In particular the device is refused *before*
    /// the tap exists, because the tap is what mutes the machine.
    private func startEngine() throws {
        teardownEngine()

        let device = try resolveOutputDevice()
        try refuseUnusableDevice(device)

        let taps = try makeTaps(for: device)
        tapIDs = taps.map(\.id)

        aggregateID = try makeAggregate(around: device, taps: taps)
        try refuseAggregateWithoutOutput(aggregateID, deviceName: device.name)

        let rate = try nominalSampleRate(of: aggregateID)
        processor.setSampleRate(rate)
        sampleRate = rate

        let layout = OutputPlan.layout(
            forTaps: taps,
            deviceChannels: AudioDevices.outputChannelCount(of: device.id),
            preferredStereo: AudioDevices.preferredStereoPair(of: device.id),
            inputBuffers: AudioDevices.inputBufferChannels(of: device.id).count)
        processor.setOutputLayout(layout)

        try startIOProc(on: aggregateID)

        // Only the two tied to this aggregate. The device and wake observers are
        // installed by `start()`, so that they exist even when this throws.
        installSampleRateListener()
        installStreamConfigurationListener()

        diagnostics = DiagnosticsReport.Engine(
            status: "running",
            deviceName: device.name,
            sampleRate: rate,
            tapChannels: layout.tapChannels,
            isDeviceBound: taps[0].isDeviceBound,
            boundStream: taps[0].stream,
            destinations: layout.destinations,
            aggregateChannels: AudioDevices.outputChannelCount(of: aggregateID),
            tapBufferIndex: layout.tapBufferIndex,
            routedChannels: layout.routedChannels,
            tapCount: taps.count
        )

        status = .running(deviceName: device.name)
        logger.info("Engine running on \(device.name, privacy: .public)")
    }

    /// The output device everything is built around.
    private struct OutputDevice {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// Reads the current default output through `AudioDevices`, which is the one
    /// place these properties are read, and turns "no device" into an error
    /// rather than a nil that has to be handled six lines later.
    private func resolveOutputDevice() throws -> OutputDevice {
        guard let id = AudioDevices.defaultOutputDeviceID() else {
            throw CoreAudioError(
                status: OSStatus(kAudioHardwareBadDeviceError),
                operation: "reading the default output device")
        }
        guard let uid = AudioDevices.persistentID(of: id) else {
            throw CoreAudioError(
                status: OSStatus(kAudioHardwareBadDeviceError), operation: "reading the device UID")
        }
        return OutputDevice(id: id, uid: uid, name: AudioDevices.name(of: id) ?? "Unknown Device")
    }

    /// Core Audio will not nest one aggregate device inside another, and it does
    /// not say so. Handed an Aggregate or Multi-Output Device as a sub-device,
    /// `AudioHardwareCreateAggregateDevice` still returns noErr — it silently
    /// drops the sub-device, leaving an aggregate with no active sub-devices and
    /// no output streams at all. `AudioDeviceStart` then succeeds on that empty
    /// device and the IO proc runs normally, handed real tapped audio and an
    /// output buffer list with zero buffers, so `EQProcessor.render` writes
    /// nowhere and every stage no-ops in silence.
    ///
    /// Meanwhile the tap goes on muting every other process at the hardware. The
    /// result is a completely silent Mac while the app reports that it is
    /// working, and bypass does not rescue it because bypass does not release
    /// the tap. Refusing here — before the tap exists — is what keeps a
    /// configuration CoreEQ cannot serve from taking the machine's audio down
    /// with it.
    private func refuseUnusableDevice(_ device: OutputDevice) throws {
        guard AudioDevices.isAggregate(device.id) else { return }
        throw UnusableOutputDevice.aggregateDevice(name: device.name)
    }

    /// The taps this device needs, and the permission fact that follows.
    private func makeTaps(for device: OutputDevice) throws -> [AssembledTap] {
        // Tap every process except our own output, otherwise the equalized
        // signal we play back would be captured again as a feedback loop.
        var excluded: [AudioObjectID] = []
        if let selfObject = try? processObjectID(for: getpid()) {
            excluded.append(selfObject)
        }

        let factory = LiveTapFactory(outputUID: device.uid, excluded: excluded)
        defer {
            // Whether a tap was ever created is the only ground truth about the
            // permission, and it is true whether or not the engine went on to
            // start.
            if factory.didCreateATap { tapAccess = .granted }
        }

        let taps = try TapAssembly.taps(
            forStreams: AudioDevices.outputStreamChannelCounts(of: device.id), using: factory)
        let channels = taps.reduce(0) { $0 + $1.channels }
        logger.info(
            "Taps: \(taps.count, privacy: .public), \(channels, privacy: .public) channels")
        return taps
    }

    /// The private aggregate that carries the device and the taps together.
    private func makeAggregate(
        around device: OutputDevice, taps: [AssembledTap]
    ) throws
        -> AudioObjectID
    {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CoreEQ Aggregate",
            kAudioAggregateDeviceUIDKey:
                "\(AudioDevices.coreEQAggregateUIDPrefix)\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            // One entry per tap. A device presenting several output streams needs
            // one tap each, and the aggregate carries them all.
            kAudioAggregateDeviceTapListKey: taps.map { tap in
                [
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            },
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &id),
            "creating the aggregate device")
        return id
    }

    /// The invariant the guard above cannot cover: an aggregate reporting
    /// success is not evidence that it has anywhere to put audio, and running an
    /// IO proc against one that does not is indistinguishable from working, from
    /// the inside.
    private func refuseAggregateWithoutOutput(_ id: AudioObjectID, deviceName: String) throws {
        guard !AudioDevices.hasOutputChannels(id) else { return }
        throw UnusableOutputDevice.noOutputStreams(name: deviceName)
    }

    private func startIOProc(on aggregate: AudioObjectID) throws {
        var id: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&id, aggregate, nil, Self.ioBlock(for: processor)),
            "creating the IO proc")
        ioProcID = id
        try check(AudioDeviceStart(aggregate, id), "starting the aggregate device")
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

    /// The live tap factory: the Core Audio calls, and nothing else.
    ///
    /// Everything deciding *which* taps a device needs, and what to do when only
    /// some of them can be made, lives in `TapAssembly` where a test can reach
    /// it. Those decisions are the part that has been wrong. This is the part
    /// that cannot be tested without the hardware.
    private final class LiveTapFactory: TapFactory {
        let outputUID: String
        let excluded: [AudioObjectID]
        /// Set the moment any tap is created, which is the only ground truth
        /// about the permission there is.
        private(set) var didCreateATap = false

        init(outputUID: String, excluded: [AudioObjectID]) {
            self.outputUID = outputUID
            self.excluded = excluded
        }

        func makeDeviceBoundTap(stream: Int) throws -> AssembledTap {
            try make(
                CATapDescription(
                    __excludingProcesses: excluded.map(NSNumber.init(value:)),
                    andDeviceUID: outputUID, withStream: stream),
                isDeviceBound: true, stream: stream)
        }

        func makeGlobalTap() throws -> AssembledTap {
            try make(
                CATapDescription(stereoGlobalTapButExcludeProcesses: excluded),
                isDeviceBound: false, stream: -1)
        }

        func destroy(_ tap: AssembledTap) {
            AudioHardwareDestroyProcessTap(tap.id)
        }

        private func make(
            _ description: CATapDescription, isDeviceBound: Bool, stream: Int
        ) throws -> AssembledTap {
            description.name = "CoreEQ System Tap"
            description.muteBehavior = .mutedWhenTapped
            description.isPrivate = true

            var id = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(description, &id)
            guard status == noErr else { throw TapUnavailable(status: status) }
            didCreateATap = true

            let format = Self.format(of: id)
            // A tap the render path cannot read is worse than no tap: it would
            // mute every other process and play back reinterpreted bytes.
            guard format.isRenderable else {
                AudioHardwareDestroyProcessTap(id)
                throw UnrenderableTapFormat()
            }
            return AssembledTap(
                id: id, uuid: description.uuid, channels: format.channels,
                stream: stream, isDeviceBound: isDeviceBound)
        }

        private static func format(of tap: AudioObjectID) -> (channels: Int, isRenderable: Bool) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
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
