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

        /// A few words for surfaces that cannot afford a sentence.
        var summary: String? {
            switch self {
            case .stopped, .running: return nil
            case .failed(let summary, _): return summary
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
    var isProcessing: Bool { Self.isProcessing(status: status, isEnabled: isEnabled) }

    /// The same question, asked of values rather than of the engine.
    ///
    /// `@Published` emits in `willSet`, so a subscriber reading these properties
    /// back is reading the value being replaced. Anything reacting to a change
    /// has to answer from what Combine handed it, and this is how.
    nonisolated static func isProcessing(status: Status, isEnabled: Bool) -> Bool {
        guard isEnabled, case .running = status else { return false }
        return true
    }

    /// Whether asking for the equalizer to be on can achieve anything.
    ///
    /// False while the engine cannot run at all — an output device it has to
    /// refuse, say. Switching on then changes a stored preference and nothing
    /// else, so the switch is disabled rather than left to report a state the
    /// sound does not have.
    var canProcess: Bool { Self.canProcess(status: status) }

    /// Whether the tap has delivered anything but silence since it started.
    ///
    /// Read on demand rather than published. It changes once, on the render
    /// thread, and the only thing that wants it is a diagnostics report being
    /// drawn — publishing it would mean waking the UI for a fact nobody is
    /// looking at.
    var hasReceivedAudio: Bool { processor.hasReceivedAudio }

    /// The widest interval the render path has spent filtering at a rate the
    /// device was not using. Nil when there has been none, which is every
    /// measurement so far.
    /// How long the current audio path has been up. Nil when it is not.
    ///
    /// What gives "no audio seen" its meaning: after three seconds it says
    /// nothing at all, and after twenty minutes it says a great deal.
    var uptime: TimeInterval? { startedAt.map { -$0.timeIntervalSinceNow } }

    /// What has made the engine rebuild itself this session.
    var restarts: DiagnosticsReport.Restarts {
        DiagnosticsReport.Restarts(
            count: restartCount,
            lastReason: lastRestartReason,
            since: lastRestartAt.map { -$0.timeIntervalSinceNow })
    }

    /// The loudest thing the chain has produced, and whether any of it did not
    /// fit.
    var level: DiagnosticsReport.Level {
        DiagnosticsReport.Level(
            peak: processor.peakLevel, clippedSamples: processor.clippedSamples)
    }

    /// Whether the audio device has been let go, and the history of that.
    var idling: DiagnosticsReport.Idling {
        DiagnosticsReport.Idling(
            isIdle: isIdle,
            isEnabled: settings.pausesWhenSilent,
            releases: idleCount,
            totalSeconds: totalIdle + (idleSince.map { -$0.timeIntervalSinceNow } ?? 0))
    }

    var rateWindow: RateWindow.Measurement? {
        let trace = processor.rateTrace.snapshot()
        return RateWindow.widest(
            RateWindow.readings(trace.cycles, ticksPerSecond: RateTrace.ticksPerSecond))
    }

    /// Whether what stands between the user and their equalizer is the
    /// permission, rather than anything about their device.
    ///
    /// True when capturing was refused. Declining otherwise leaves the app
    /// running with an error saying the audio was not allowed — accurate, and
    /// useless. This is what swaps that for a screen saying where to allow it.
    var needsAudioPermission: Bool { tapAccess == .denied }

    /// As `canProcess`, from a status rather than from the engine. See
    /// `isProcessing(status:isEnabled:)`.
    nonisolated static func canProcess(status: Status) -> Bool {
        switch status {
        case .failed: return false
        case .stopped, .running: return true
        }
    }

    /// Global bypass. When false the engine keeps running but passes audio
    /// through untouched, so toggling is instant and glitch-free.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            processor.setBypassed(!isEnabled)
            settings.isEnabled = isEnabled
            // Acted on at once rather than at the next poll, in both
            // directions: switching off should let go of the machine
            // immediately, and switching back on should not wait half a second
            // to start working.
            evaluateIdleState()
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
    private var rateTraceDump: DispatchWorkItem?

    /// When the engine last came up, and what has made it come up again.
    ///
    /// Deliberately outside the diagnostics snapshot, which is rebuilt by every
    /// start and would therefore always report a fresh engine that had never
    /// restarted. These survive teardown because the question they answer is
    /// about the session, not about this instance of the audio path: an echo
    /// after waking, or audio arriving twice, is the shape of a state change
    /// that left something behind, and a restart is the state change.
    private var startedAt: Date?
    private var restartCount = 0
    private var lastRestartReason: String?
    private var lastRestartAt: Date?
    private var streamConfigListener: AudioObjectPropertyListenerBlock?
    private var wakeObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?
    /// A rebuild that has been scheduled but has not run yet.
    ///
    /// Nil means none is pending, and that has to stay true: it is read as a
    /// "mid-transition" flag, not just as something to cancel. It was cancelled
    /// but never cleared once, and the stale reference made the engine believe a
    /// restart was permanently in flight — which silently disabled idling for
    /// every session, because the device-change listener fires once at launch.
    /// Cleared in all three places it can end: cancelled by `start`, cancelled
    /// by `stop`, and completed by its own work item.
    private var pendingRestart: DispatchWorkItem?
    private var capturePoll: DispatchWorkItem?
    private var idlePoll: DispatchWorkItem?

    /// What tells the engine that audio is starting, so a resume is not waiting
    /// on a timer.
    ///
    /// Push, not poll, because the delay before CoreEQ starts processing again
    /// is heard: at a half-second poll roughly a second of audio played
    /// unequalized, which was reported as very noticeable. The device itself
    /// needs about 90 ms to deliver its first buffer after `AudioDeviceStart`,
    /// so anything above that is the app's own dithering.
    ///
    /// Two listeners, because measurement ruled out the obvious one.
    /// `kAudioProcessPropertyIsRunningOutput` sends no notifications at all —
    /// attached to every process, it never fired once — and sweeping every
    /// process by hand costs 6 ms a pass, far too much to do often.
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` does notify, costs 0.05 ms
    /// to read, and is false while CoreEQ is idle, so it says exactly what is
    /// wanted: somebody else wants this device.
    private var deviceRunningListener: AudioObjectPropertyListenerBlock?
    /// A process appearing in the audio process list, which measured about 80 ms
    /// *before* it starts playing — enough of a head start to cover the device's
    /// own warm-up.
    private var processListListener: AudioObjectPropertyListenerBlock?
    /// Set by that listener and cleared once acted on.
    private var audioStarting = false
    /// The device the aggregate is built around, which is what the running
    /// listener watches — not the aggregate, whose own state is CoreEQ's.
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)

    /// Whether the audio path has been released because nothing was playing.
    ///
    /// Deliberately *not* part of `Status`. From the user's side nothing has
    /// changed — CoreEQ is on, and the next sound will be equalized — so the
    /// menu bar icon must go on saying so. An idle engine that reported itself
    /// stopped would blink the icon off every time a room went quiet.
    private(set) var isIdle = false
    private var idleCount = 0
    private var idleSince: Date?
    private var totalIdle: TimeInterval = 0
    /// Whether a tap has been seen delivering audio in this session.
    ///
    /// Not persisted. A permission can be withdrawn between launches, and the
    /// cost of proving it again is a moment of unprocessed audio — far less than
    /// the cost of trusting a stale yes and muting the Mac.
    private var captureProven = false
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
        pendingRestart = nil
        // The verdict belongs to the attempt that produced it. Carrying it into
        // the next one would leave the app reporting a refusal it is in the
        // middle of retrying.
        if tapAccess == .denied { tapAccess = .unknown }
        // Before the attempt, not after it. These two outlive any single
        // aggregate device — that is the point of them — and installing them at
        // the end of `startEngine` meant a start that threw never installed
        // them at all. Refusing an unsupported output device does throw, and
        // deliberately does not retry, so the engine was left with no way to
        // learn that the user had switched to a device it could serve: the
        // failure was permanent in the strong sense, until the app was
        // relaunched. Installed here, a device change always gets a hearing.
        installDefaultDeviceListenerIfNeeded()
        installPlaybackListenersIfNeeded()
        installWakeObserverIfNeeded()
        installActivationObserverIfNeeded()
        do {
            try startEngine()
            retryCount = 0
            isIdle = false
            scheduleIdleCheck()
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
        pendingRestart = nil
        idlePoll?.cancel()
        idlePoll = nil
        removeSystemObservers()
        teardownEngine()
        diagnostics = nil
        startedAt = nil
        isIdle = false
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
        installDeviceRunningListener(on: device.id)

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
            tapCount: taps.count,
            isMuting: captureProven
        )

        processor.resetAudioObservation()
        processor.isProvingCapture = !captureProven
        if !captureProven { startProvingCapture() }

        startedAt = Date()
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

        let factory = LiveTapFactory(
            outputUID: device.uid, excluded: excluded,
            muteBehavior: captureProven ? .mutedWhenTapped : .unmuted)
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
        { now, input, _, output, _ in
            processor.render(input: input, output: output, now: now)
        }
    }

    private func teardownEngine() {
        capturePoll?.cancel()
        capturePoll = nil

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

    /// How often to look for the first sample.
    private static let capturePollInterval: TimeInterval = 0.25

    /// How often the idle decision is revisited when nothing has told us to.
    ///
    /// A backstop, not the mechanism: `playbackListeners` is what makes resuming
    /// prompt, and this only catches anything they miss. Slow on purpose — going
    /// idle a couple of seconds late costs nothing against a thirty second
    /// threshold, and a timer that fires rarely is a timer that costs no
    /// battery.
    private static let idlePollInterval: TimeInterval = 2.0

    /// How long the tap may deliver nothing *while something else is playing*
    /// before the engine says it is not capturing.
    ///
    /// Short, because the condition is specific: audio is demonstrably flowing
    /// and none of it is reaching us. Long enough to cover a tap that takes a
    /// moment to start after the aggregate does.
    private static let silenceWhilePlayingLimit: TimeInterval = 2

    /// Waits for evidence that the tap is delivering, then mutes.
    ///
    /// Until the first sample arrives the tap is unmuted and the render path
    /// writes nothing, so the Mac sounds exactly as it would without CoreEQ. The
    /// equalizer is not applied during that window, which is the price of not
    /// muting a machine we might not be able to capture from.
    ///
    /// The engine is rebuilt rather than the live tap being modified. A tap's
    /// description is writable in principle, but a rebuild uses only operations
    /// already proven to work here, and it happens once per session.
    private func startProvingCapture(silentWhilePlaying: TimeInterval = 0) {
        capturePoll?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ioProcID != nil, !self.captureProven else { return }

            let (verdict, silent) = CaptureProof.evaluate(
                hasReceivedAudio: self.processor.hasReceivedAudio,
                isAnythingPlaying: AudioDevices.isAnyProcessPlayingOutput(
                    excluding: self.tapExcludedProcess),
                silentWhilePlaying: silentWhilePlaying,
                interval: Self.capturePollInterval,
                limit: Self.silenceWhilePlayingLimit)

            if verdict == .proven {
                self.logger.info("Tap is delivering audio; muting and restarting to process it")
                self.captureProven = true
                self.start()
                return
            }

            if verdict == .notCapturing, self.tapAccess != .denied {
                // Audio is playing and none of it is reaching the tap. Say so,
                // and leave the sound alone — the tap is unmuted, so the only
                // thing wrong is that CoreEQ is not equalizing.
                self.logger.error("Audio is playing but the tap is silent; leaving it unmuted")
                self.tapAccess = .denied
                self.status = .failed(
                    summary: "Not capturing audio",
                    message:
                        "CoreEQ is not receiving any audio, so it is leaving your sound alone "
                        + "rather than replacing it. This is what a refused permission looks "
                        + "like.")
            }
            // Kept watching either way. A verdict here is a reading of the
            // moment, not a sentence: allow the permission and the next sound
            // proves the tap, which promotes it and clears this.
            self.startProvingCapture(silentWhilePlaying: silent)
        }
        capturePoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.capturePollInterval, execute: work)
    }

    // MARK: - Idling

    /// Revisits the idle decision on a timer, forever.
    ///
    /// One timer covers both directions. While running it is asking whether the
    /// device can be let go; while idle it is asking whether anything wants to
    /// play. Two timers would be two things to keep in step, and the state they
    /// disagreed about would be whether the Mac has any audio at all.
    private func scheduleIdleCheck() {
        idlePoll?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluateIdleState()
            self.scheduleIdleCheck()
        }
        idlePoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idlePollInterval, execute: work)
    }

    /// Acts on `IdlePolicy`, and does nothing else.
    ///
    /// Every condition lives in the policy so that it can be tested without an
    /// audio device; this is only the hands. Anything resembling a decision that
    /// appears here belongs there instead.
    private func evaluateIdleState() {
        // Never while the tap is still being proved, and never while a restart
        // is already in flight: both are mid-transition, and a teardown from
        // underneath either leaves state describing a path that no longer
        // exists.
        guard !isMidTransition else { return }

        // Two different questions, because "is anyone playing" has two different
        // right answers depending on whether CoreEQ is one of them. Idle, the
        // device is not ours and its own running flag is both cheaper and
        // faster. Running, it would always be true — we are the one using it —
        // so the processes have to be asked instead, excluding ourselves.
        //
        // And running, the question is only asked when it can change the answer.
        // Sweeping every audio process costs about 6 ms; below the silence
        // threshold the verdict is `keepRunning` whatever it returns, so paying
        // that every couple of seconds for the whole life of the app would be
        // battery spent to confirm something already known.
        let isAnythingPlaying: Bool
        if isIdle {
            isAnythingPlaying = AudioDevices.isRunningSomewhere(outputDeviceID)
        } else if processor.silentSeconds >= IdlePolicy.idleAfter {
            isAnythingPlaying = AudioDevices.isAnyProcessPlayingOutput(
                excluding: tapExcludedProcess)
        } else {
            isAnythingPlaying = false
        }

        let verdict = IdlePolicy.evaluate(
            isRunning: !isIdle && ioProcID != nil,
            silentSeconds: processor.silentSeconds,
            isAnythingPlaying: isAnythingPlaying,
            isEnabled: isEnabled,
            isCaptureProven: captureProven,
            pausesWhenSilent: settings.pausesWhenSilent,
            isAudioStarting: audioStarting,
            isRecovering: status.summary != nil)
        audioStarting = false

        switch verdict {
        case .keepRunning, .stayIdle:
            return
        case .goIdle:
            goIdle()
        case .resume:
            resumeFromIdle()
        }
    }

    /// Whether the engine is between states, and must not be touched.
    ///
    /// A rebuild already scheduled, or a tap still being proved. Tearing down
    /// from under either leaves state describing a path that no longer exists —
    /// and in the proving case it would destroy the very path that has to run
    /// for the permission answer to arrive.
    private var isMidTransition: Bool {
        pendingRestart != nil || (capturePoll != nil && !captureProven)
    }

    /// Releases the sleep assertion by stopping the IO proc, and nothing else.
    ///
    /// The tap and the aggregate stay alive on purpose. The first version of
    /// this tore the whole path down and rebuilt it on resume, which broke
    /// playback outright over Bluetooth: rebuilding means creating a new
    /// aggregate around the output device at the exact moment a player is
    /// opening that device, so the device is reconfigured — and on Bluetooth
    /// renegotiated — underneath the client that just grabbed it. Players failed
    /// to start and only succeeded after several attempts, because each attempt
    /// was a race against us.
    ///
    /// Stopping is enough. `AudioDeviceStop` alone releases the assertion, and
    /// a tap left alive does *not* silence other processes while nothing is
    /// consuming it — both measured, the second because assuming it would was
    /// what made the destructive version look necessary. So while idle, audio
    /// plays normally and unprocessed, and resuming touches no topology at all.
    private func goIdle() {
        guard !isIdle, let ioProcID, aggregateID != kAudioObjectUnknown else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        isIdle = true
        idleCount += 1
        idleSince = Date()
        // `status` is deliberately untouched. Nothing has changed for the user:
        // CoreEQ is on, and the next sound will be equalized.
        logger.info("Idle: stopped the IO proc, nothing is playing")
    }

    /// Starts the IO proc again because something wants to play.
    ///
    /// One call, against a device that was never taken apart. Nothing is
    /// created, nothing is renegotiated, and the player that triggered this
    /// keeps the device it just opened.
    private func resumeFromIdle() {
        guard isIdle else { return }
        guard let ioProcID, aggregateID != kAudioObjectUnknown else {
            // The path went away underneath us — a device change, or a failed
            // start. Rebuilding is the only option left, and it is safe here
            // because there is nothing to disturb.
            isIdle = false
            start()
            return
        }
        if let idleSince { totalIdle += -idleSince.timeIntervalSinceNow }
        idleSince = nil
        isIdle = false
        // The delay lines describe audio from before the pause.
        processor.prepareForResume()
        let status = AudioDeviceStart(aggregateID, ioProcID)
        if status != noErr {
            logger.error("Resume failed (\(status)); rebuilding")
            start()
            return
        }
        logger.info("Resuming: audio is playing")
    }

    /// Our own audio process object, so our playback is not counted as evidence
    /// that audio is reaching everything *except* us.
    private var tapExcludedProcess: AudioObjectID {
        (try? processObjectID(for: getpid())) ?? AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Change handling

    /// Removes the observers that survive a restart. `start()` reinstalls both,
    /// so stopping and starting again is a complete cycle.
    /// Watches for anything starting to play, so a resume does not wait for a
    /// timer.
    ///
    /// Two kinds are needed and one alone is not enough: a listener per process
    /// catches an app that is already known to Core Audio, and a listener on the
    /// process list catches one that has just appeared — measured, a freshly
    /// launched player fires no per-process notification, because there was no
    /// process object to attach to when the listeners went on.
    private func installPlaybackListenersIfNeeded() {
        guard processListListener == nil else { return }
        var addr = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioStarting = true
                self.evaluateIdleState()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        if status == noErr {
            processListListener = block
        } else {
            logger.error("Failed to observe the audio process list: \(status)")
        }
    }

    /// Watches the output device for anyone else starting to use it.
    ///
    /// On the device rather than the aggregate: the aggregate's running state is
    /// CoreEQ's own, and would say nothing about who else wants to play.
    private func installDeviceRunningListener(on deviceID: AudioObjectID) {
        removeDeviceRunningListener()
        var addr = propertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.evaluateIdleState() }
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &addr, .main, block) == noErr {
            deviceRunningListener = block
            outputDeviceID = deviceID
        } else {
            logger.error("Failed to observe whether \(deviceID) is in use")
        }
    }

    private func removeDeviceRunningListener() {
        if let deviceRunningListener, outputDeviceID != kAudioObjectUnknown {
            var addr = propertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(
                outputDeviceID, &addr, .main, deviceRunningListener)
        }
        deviceRunningListener = nil
        outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func removePlaybackListeners() {
        if let processListListener {
            var addr = propertyAddress(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, .main, processListListener)
        }
        processListListener = nil
        removeDeviceRunningListener()
    }

    private func removeSystemObservers() {
        removePlaybackListeners()
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

        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil

    }

    private func scheduleRestart(after delay: TimeInterval, reason: String) {
        logger.info("Restart scheduled: \(reason, privacy: .public)")
        restartCount += 1
        lastRestartReason = reason
        lastRestartAt = Date()
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRestart = nil
            self?.start()
        }
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
        let block: AudioObjectPropertyListenerBlock = { [processor] _, _ in
            // Marked here rather than after the hop, so the trace shows what the
            // hop itself costs.
            processor.rateTrace.mark(.listenerFired)
            Task { @MainActor [weak self] in
                guard let self, self.aggregateID == deviceID else { return }
                if let rate = try? self.nominalSampleRate(of: deviceID) {
                    self.processor.setSampleRate(rate)
                    self.processor.rateTrace.mark(.rateStaged, rate: rate)
                    self.sampleRate = rate
                    self.scheduleRateTraceDump()
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

    /// Logs the trace once the cycles after a rate change have been recorded.
    ///
    /// A second, because the far edge of the window is what is being measured
    /// and it has not happened yet when the listener fires. Cheap to be
    /// generous: the ring holds about five seconds.
    private func scheduleRateTraceDump() {
        rateTraceDump?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let trace = self.processor.rateTrace.snapshot()
            let readings = RateWindow.readings(
                trace.cycles, ticksPerSecond: RateTrace.ticksPerSecond)
            self.logger.notice("\(RateWindow.summary(readings), privacy: .public)")

            // The full table only when there is something to explain. It runs to
            // hundreds of rows — too long for os_log, which truncates a message
            // well short of that — and on every measurement so far there has
            // been nothing in it worth keeping.
            guard RateWindow.widest(readings) != nil else { return }
            let report = RateWindow.report(cycles: trace.cycles, events: trace.events)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("coreeq-rate-trace.txt")
            try? report.write(to: url, atomically: true, encoding: .utf8)
            self.logger.notice("rate trace written to \(url.path, privacy: .public)")
        }
        rateTraceDump = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Tries again when the app comes back to the front, but only after a
    /// refusal.
    ///
    /// Someone sent to System Settings to allow capture returns to an app that
    /// gave up ten seconds after starting and has no way to learn the answer
    /// changed — audio capture has no permission API to consult. Coming back is
    /// the signal, and starting is the only way to find out.
    ///
    /// Guarded on the refusal so this is not a restart on every activation: a
    /// working engine is left alone.
    private func installActivationObserverIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.retryAfterRefusal() }
        }
    }

    private func retryAfterRefusal() {
        guard tapAccess == .denied else { return }
        logger.info("Returned to the foreground after a refusal; trying to capture again")
        start()
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
        let muteBehavior: CATapMuteBehavior
        /// Set the moment any tap is created, which is the only ground truth
        /// about the permission there is.
        private(set) var didCreateATap = false

        init(outputUID: String, excluded: [AudioObjectID], muteBehavior: CATapMuteBehavior) {
            self.outputUID = outputUID
            self.excluded = excluded
            self.muteBehavior = muteBehavior
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
            // Muting is earned, not assumed. `AudioHardwareCreateProcessTap`
            // returns success when the user has refused permission — the tap
            // reports a plausible format and delivers nothing — so a tap created
            // muted silences the Mac on the strength of a promise Core Audio has
            // not made. Unmuted, the same refusal costs only that the audio is
            // not equalized, which is how an equalizer should fail.
            description.muteBehavior = muteBehavior
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
