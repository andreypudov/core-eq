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
        case failed(String)

        var description: String {
            switch self {
            case .stopped:
                return "Audio engine stopped."
            case .running(let deviceName):
                return "Processing system audio on “\(deviceName)”."
            case .failed(let message):
                return "Audio engine error: \(message)"
            }
        }
    }

    @Published private(set) var status: Status = .stopped

    /// Rate assumed before a device has reported one. Only ever seen during
    /// launch, and replaced as soon as the aggregate device exists.
    static let defaultSampleRate = 44_100.0

    /// Nominal sample rate of the active aggregate device. The response curve
    /// uses it so the drawn filters match what the processor actually renders.
    @Published private(set) var sampleRate = AudioEngine.defaultSampleRate

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

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
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
        do {
            try startEngine()
            retryCount = 0
        } catch {
            teardownEngine()
            let message =
                (error as? CoreAudioError)?.localizedDescription ?? error.localizedDescription
            logger.error("Engine start failed: \(message, privacy: .public)")
            status = .failed(message)
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
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapDescription.name = "CoreEQ System Tap"
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(tapDescription, &newTapID),
            "creating the system audio tap (check System Audio Recording permission)")
        tapID = newTapID

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
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
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
        // thread never has to guess. The stereo pair goes to the first two output
        // channels: on a single device those are its front left and right, and on
        // an aggregate they are the main sub-device's, which is the one the user
        // nominated. Every other channel the device has stays silent.
        processor.setOutputLayout(
            EQProcessor.OutputLayout(
                tapChannels: tapChannelCount(of: tapID), leftChannel: 0, rightChannel: 1))

        let processor = self.processor
        var newProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(
                &newProcID, aggregateID, nil, Self.ioBlock(for: processor)),
            "creating the IO proc")
        ioProcID = newProcID

        try check(AudioDeviceStart(aggregateID, newProcID), "starting the aggregate device")

        installSampleRateListener()
        installDefaultDeviceListenerIfNeeded()
        installWakeObserverIfNeeded()

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

        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
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

    private func installDefaultDeviceListenerIfNeeded() {
        guard defaultDeviceListener == nil else { return }
        var addr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleRestart(after: 0.5, reason: "default output device changed")
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

    /// Channels the tap will deliver, read from the tap's own format rather than
    /// assumed from what we asked for. Falls back to stereo, which is what
    /// `CATapDescription(stereoGlobalTapButExcludeProcesses:)` builds.
    private func tapChannelCount(of tap: AudioObjectID) -> Int {
        var addr = propertyAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format) == noErr,
            format.mChannelsPerFrame > 0
        else {
            return EQProcessor.OutputLayout().tapChannels
        }
        return Int(format.mChannelsPerFrame)
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
