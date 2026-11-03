import CoreAudio
import Darwin
import Foundation

/// Measures what happens to CoreEQ when another process takes exclusive (hog)
/// access to the output device.
///
/// A second copy of this binary plays the part of the player: it takes hog mode,
/// runs an IO proc for a while, and lets go. The first copy watches from outside,
/// the way CoreEQ would have to, and records:
///
/// - `kAudioDevicePropertyHogMode`, both polled and through a listener, because a
///   property being readable says nothing about whether it notifies;
/// - whether a tap and an aggregate like CoreEQ's keep running and hear anything;
/// - whether the player could take the device at all, and whether anyone else's
///   audio still reaches it while it is held;
/// - which device macOS makes the default output meanwhile;
/// - what CoreEQ logged throughout.
///
/// It reports what happened and passes no judgement: there is no expected answer
/// yet. Run with `make hog-test`, or see `usage` for one scenario at a time.
@main
enum HogTest {
    static let usage = """
        hog-test [--device <uid>] [--seconds <n>] [--level <linear>] \
        [--background] [--no-tap] [--settle <seconds>] [--hog-delay <seconds>]

          --device      Move the default output here for the run, then restore it.
          --seconds     How long the player holds the device. Default 12, which is
                        longer than CoreEQ's six second limit on a silent tap.
          --level       The player's tone. Default 0.003, about -50 dBFS. At 0 it
                        plays silence, so anything it reads back on a loopback
                        device came from someone else.
          --background  Keep another process playing while the device is held.
          --no-tap      Run no tap of its own, which would hold the device awake
                        and keep CoreEQ from going idle.
          --settle      Seconds of quiet before the player starts. Default 2. Over
                        30 lets CoreEQ go idle first.
          --hog-delay   Seconds the player exists before it takes the device.
                        Default 0, a player launched to play. Over 30 is one left
                        open, with CoreEQ going idle in the meantime.
        """

    static let toneHz = 440.0
    static let controlSeconds = 4.0
    static let releasedSeconds = 10.0

    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "hold" {
            arguments.removeFirst()
            Player.run(arguments)
        } else {
            exit(Observer.run(arguments))
        }
    }

    // MARK: - Core Audio

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as initial: T
    ) -> T? {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static var defaultOutput: AudioDeviceID {
        read(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
            as: AudioDeviceID(0)) ?? 0
    }

    static func setDefaultOutput(_ device: AudioDeviceID) -> OSStatus {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
            let value
        else { return "?" }
        return value.takeRetainedValue() as String
    }

    static func device(uid: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func hogOwner(_ device: AudioDeviceID) -> pid_t? {
        read(device, kAudioDevicePropertyHogMode, as: pid_t(-1))
    }

    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        (read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32(0)) ?? 0) != 0
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static let started = Date()

    static func stamp(_ message: String) {
        let elapsed = String(format: "%7.3f", -started.timeIntervalSinceNow)
        print("[\(elapsed)] \(message)")
        fflush(stdout)
    }
}

// MARK: - The player

/// Behaves like a player taking exclusive access: hog mode first, then an IO proc.
enum Player {
    final class Counters: @unchecked Sendable {
        var callbacks = 0
        var inputPeak: Float = 0
        var phase = 0.0
    }

    static func run(_ arguments: [String]) -> Never {
        guard arguments.count == 4, let device = AudioDeviceID(arguments[0]),
            let seconds = Double(arguments[1]), let level = Float(arguments[2]),
            let hogDelay = Double(arguments[3])
        else {
            print("player: bad arguments")
            exit(2)
        }
        // A held device is released when its owner exits, so this bounds the
        // worst case: nothing stays locked if the observer dies. Well past the
        // 14 s a start has been measured stalling, which is the thing being
        // measured: an alarm inside that kills the player before it can report.
        alarm(UInt32(seconds + hogDelay) + 40)

        // Any Core Audio call makes this process known to the HAL, which is the
        // announcement CoreEQ acts on. The device is taken only afterwards.
        _ = HogTest.hogOwner(device)
        if hogDelay > 0 { Thread.sleep(forTimeInterval: hogDelay) }

        let me = getpid()
        var addr = HogTest.address(kAudioDevicePropertyHogMode)
        var value = me
        let setStatus = AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<pid_t>.size), &value)
        let owner = HogTest.hogOwner(device) ?? -2
        print("player \(me): took hog mode, status \(setStatus), owner now \(owner)")
        fflush(stdout)

        let took = Date()
        let counters = Counters()
        let increment = 2 * Double.pi * HogTest.toneHz
        let rate = HogTest.read(device, kAudioDevicePropertyNominalSampleRate, as: Float64(48_000)) ?? 48_000
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) {
            _, input, _, output, _ in
            counters.callbacks += 1
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                    counters.inputPeak = max(counters.inputPeak, abs(samples[i]))
                }
            }
            let list = UnsafeMutableAudioBufferListPointer(output)
            var phase = counters.phase
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let channels = max(Int(buffer.mNumberChannels), 1)
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                phase = counters.phase
                for frame in 0..<frames {
                    let sample = level * Float(sin(phase))
                    for channel in 0..<channels { samples[frame * channels + channel] = sample }
                    phase += increment / rate
                }
            }
            counters.phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
        }
        let startStatus = procID.map { AudioDeviceStart(device, $0) } ?? createStatus
        let startTook = String(format: "%.3f", -took.timeIntervalSinceNow)
        print("player \(me): IO proc create \(createStatus), start \(startStatus), \(startTook) s")
        fflush(stdout)

        Thread.sleep(forTimeInterval: seconds)

        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        print(
            "player \(me): \(counters.callbacks) callbacks, input peak "
                + String(format: "%.6f", counters.inputPeak))
        // Setting the property while owning it is what releases it.
        var release = me
        let releaseStatus = AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<pid_t>.size), &release)
        print("player \(me): released, status \(releaseStatus)")
        fflush(stdout)
        exit(0)
    }
}

// MARK: - The observer

enum Observer {
    /// Written by the IO proc, read between phases. Torn reads only cost a
    /// slightly wrong number in a report.
    final class Probe: @unchecked Sendable {
        var callbacks = 0
        var peak: Float = 0
        func take() -> (callbacks: Int, peak: Float) {
            defer {
                callbacks = 0
                peak = 0
            }
            return (callbacks, peak)
        }
    }

    final class Listening: @unchecked Sendable {
        var hogNotifications = 0
    }

    static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func run(_ arguments: [String]) -> Int32 {
        if arguments.contains("--help") {
            print(HogTest.usage)
            return 0
        }
        let seconds = Double(option("--seconds", in: arguments) ?? "") ?? 12
        let level = option("--level", in: arguments) ?? "0.003"
        let settle = Double(option("--settle", in: arguments) ?? "") ?? 2
        let background = arguments.contains("--background")
        let useTap = !arguments.contains("--no-tap")
        let hogDelay = Double(option("--hog-delay", in: arguments) ?? "") ?? 0

        let originalDefault = HogTest.defaultOutput
        var device = originalDefault
        if let uid = option("--device", in: arguments) {
            guard let requested = HogTest.device(uid: uid) else {
                print("No device with UID \(uid)")
                return 2
            }
            device = requested
        }
        let restore: @Sendable () -> Void = {
            if HogTest.defaultOutput != originalDefault {
                let status = HogTest.setDefaultOutput(originalDefault)
                HogTest.stamp("restored default output, status \(status)")
            }
        }
        // Never leave the Mac on the wrong output, however this goes.
        let limit =
            HogTest.controlSeconds + settle + hogDelay + seconds + HogTest.releasedSeconds + 30
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
            HogTest.stamp("watchdog: gave up after \(Int(limit)) s")
            restore()
            exit(3)
        }
        if device != originalDefault {
            let status = HogTest.setDefaultOutput(device)
            HogTest.stamp("moved default output, status \(status)")
            Thread.sleep(forTimeInterval: 3)
        }
        defer { restore() }

        let coreEQ = coreEQPID()
        HogTest.stamp(
            "device \(device) \"\(HogTest.string(device, kAudioObjectPropertyName))\", "
                + "hog owner \(HogTest.hogOwner(device).map(String.init) ?? "unreadable"), "
                + "CoreEQ pid \(coreEQ.map(String.init) ?? "not running")")
        HogTest.stamp(
            "player holds \(seconds) s at level \(level), settle \(settle) s, "
                + "background \(background), tap \(useTap)")

        let logFile = startLogStream()

        let listening = Listening()
        var hogAddress = HogTest.address(kAudioDevicePropertyHogMode)
        let queue = DispatchQueue(label: "hog-test.listener")
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            listening.hogNotifications += 1
            HogTest.stamp(
                "LISTENER hog owner \(HogTest.hogOwner(device).map(String.init) ?? "unreadable")")
        }
        let listenerStatus = AudioObjectAddPropertyListenerBlock(device, &hogAddress, queue, listener)
        HogTest.stamp("hog listener installed, status \(listenerStatus)")

        let stopWatching = watch(device: device, coreEQ: coreEQ)

        let probe = Probe()
        let tap = useTap ? TapProbe(device: device, excluding: coreEQ, probe: probe) : nil

        let tone = writeTone(seconds: limit + 5)
        var other = startBackground(tone)

        phase("control: another process playing, no hog", seconds: HogTest.controlSeconds, probe)

        if !background {
            other?.terminate()
            other = nil
            phase("quiet before the player", seconds: settle, probe)
        }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        player.arguments = ["hold", String(device), String(seconds), level, String(hogDelay)]
        let playerStatus: String
        do {
            try player.run()
            playerStatus = "pid \(player.processIdentifier)"
        } catch {
            playerStatus = "failed: \(error)"
        }
        HogTest.stamp("player started, \(playerStatus)")
        if hogDelay > 0 { phase("player open, not holding yet", seconds: hogDelay, probe) }
        phase("player holding the device", seconds: seconds, probe)
        player.waitUntilExit()

        phase("after release", seconds: HogTest.releasedSeconds, probe)

        other?.terminate()
        stopWatching()
        tap?.stop()
        AudioObjectRemovePropertyListenerBlock(device, &hogAddress, queue, listener)

        let alive = coreEQ.map { kill($0, 0) == 0 }
        HogTest.stamp("hog notifications received: \(listening.hogNotifications)")
        HogTest.stamp("CoreEQ still running: \(alive.map(String.init) ?? "n/a")")
        print("\n--- CoreEQ log ---")
        Thread.sleep(forTimeInterval: 0.5)
        logFile.stream.terminate()
        print((try? String(contentsOf: logFile.url, encoding: .utf8)) ?? "(no log)")
        try? FileManager.default.removeItem(at: logFile.url)
        try? FileManager.default.removeItem(at: tone)
        return 0
    }

    static func phase(_ name: String, seconds: Double, _ probe: Probe) {
        _ = probe.take()
        HogTest.stamp("PHASE \(name)")
        Thread.sleep(forTimeInterval: seconds)
        let (callbacks, peak) = probe.take()
        HogTest.stamp(
            "  tap probe: \(callbacks) callbacks, peak " + String(format: "%.6f", peak))
    }

    static func coreEQPID() -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "CoreEQ"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    static func startLogStream() -> (stream: Process, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hog-test-\(getpid()).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let stream = Process()
        stream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        stream.arguments = [
            "stream", "--style", "compact", "--level", "debug", "--predicate",
            "subsystem == \"com.andreypudov.coreeq\"",
        ]
        stream.standardOutput = try? FileHandle(forWritingTo: url)
        stream.standardError = FileHandle.nullDevice
        try? stream.run()
        Thread.sleep(forTimeInterval: 0.5)
        return (stream, url)
    }

    /// Polls what does not notify, or might not, and reports only changes.
    static func watch(device: AudioDeviceID, coreEQ: pid_t?) -> @Sendable () -> Void {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "hog-test.poll"))
        let process = coreEQ.flatMap(HogTest.processObject)
        var last = ""
        timer.schedule(deadline: .now(), repeating: 0.05)
        timer.setEventHandler {
            let owner = HogTest.hogOwner(device).map(String.init) ?? "unreadable"
            let running = HogTest.isRunningSomewhere(device)
            var coreEQOutput = "?"
            if let process,
                let isRunning = HogTest.read(
                    process, kAudioProcessPropertyIsRunningOutput, as: UInt32(0))
            {
                coreEQOutput = isRunning != 0 ? "yes" : "no"
            }
            let defaultName = HogTest.string(HogTest.defaultOutput, kAudioObjectPropertyName)
            let now =
                "hog owner \(owner), device running \(running), CoreEQ output \(coreEQOutput), "
                + "default output \"\(defaultName)\""
            if now != last {
                HogTest.stamp("POLL \(now)")
                last = now
            }
        }
        timer.resume()
        return { timer.cancel() }
    }

    static func startBackground(_ tone: URL) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [tone.path]
        do {
            try process.run()
            return process
        } catch {
            HogTest.stamp("could not start background audio: \(error)")
            return nil
        }
    }

    /// 16-bit mono 660 Hz at about -50 dBFS, so it can be told from the player's tone. Written by hand so that nothing here
    /// depends on a framework that might itself touch the device.
    static func writeTone(seconds: Double) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hog-test-\(getpid()).wav")
        let rate = 48_000
        let frames = Int(seconds) * rate
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(frames * 2))
        data.reserveCapacity(data.count + frames * 2)
        for frame in 0..<frames {
            append(Int16(100 * sin(2 * Double.pi * 660 * Double(frame) / Double(rate))))
        }
        try? data.write(to: url)
        return url
    }
}

// MARK: - A tap built like CoreEQ's

/// An unmuted global tap in a private aggregate around the same device, which is
/// CoreEQ's shape without the sound. It leaves CoreEQ out, so that what it hears
/// is everyone else, before any EQ.
final class TapProbe {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init?(device: AudioDeviceID, excluding coreEQ: pid_t?, probe: Observer.Probe) {
        let excluded = coreEQ.flatMap(HogTest.processObject).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "hog-test"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else {
            HogTest.stamp("tap probe: could not create the tap, status \(tapStatus)")
            return nil
        }
        let uid = HogTest.string(device, kAudioDevicePropertyDeviceUID)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "hog-test",
            kAudioAggregateDeviceUIDKey: "hog-test-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregate)
        guard aggregateStatus == noErr else {
            HogTest.stamp("tap probe: could not create the aggregate, status \(aggregateStatus)")
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) {
            _, input, _, _, _ in
            probe.callbacks += 1
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                    probe.peak = max(probe.peak, abs(samples[i]))
                }
            }
        }
        let startStatus = procID.map { AudioDeviceStart(aggregate, $0) } ?? createStatus
        HogTest.stamp("tap probe: running, create \(createStatus), start \(startStatus)")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        AudioHardwareDestroyAggregateDevice(aggregate)
        AudioHardwareDestroyProcessTap(tap)
    }
}
