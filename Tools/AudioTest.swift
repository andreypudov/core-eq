import CoreAudio
import Darwin
import Foundation

/// End-to-end check that CoreEQ produces correct audio on real hardware.
///
/// Every serious defect in this project has been at a boundary the unit tests
/// cannot reach — Core Audio reporting success for a device that plays nothing,
/// a tap created without permission, a channel map that put audio somewhere
/// else, a rebuild that broke playback. What they have in common is that the
/// app kept reporting that it worked. The only thing that catches those is
/// listening to what actually comes out, so that is what this does.
///
/// It plays a known signal through the real application and captures what
/// reaches the device, using BlackHole so nothing is audible and nothing
/// depends on speakers. The audio settings it changes are restored on the way
/// out, including after a failure.
///
/// Run with `make audio-test`.
enum AudioTest {

    // MARK: - Test signal

    /// Left and right carry different tones, so a channel map that swaps or
    /// smears them is a failure rather than something that still sounds fine.
    static let leftHz = 440.0
    static let rightHz = 1_320.0
    static let amplitude = 0.4
    static let rate = 48_000.0
    static let toneSeconds = 2.5

    // MARK: - Results

    struct Measurement {
        /// Magnitude at each test frequency, per device channel.
        var atLeft: [Double]
        var atRight: [Double]
        /// Broadband RMS per channel.
        var rms: [Double]
        var channels: Int

        func decibels(_ magnitude: Double) -> Double {
            magnitude > 0 ? 20 * log10(magnitude) : -200
        }
    }

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    /// Reported, but not counted either way: a check whose precondition does
    /// not hold on this machine. Saying so is the point — a check that quietly
    /// did not run is worse than one that failed.
    static func skip(_ name: String, _ reason: String) {
        print("  SKIP  \(name)  — \(reason)")
    }

    static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks += 1
        if passed {
            print("  PASS  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        } else {
            failures += 1
            print("  FAIL  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }
    }

    static func note(_ text: String) { print("        \(text)") }
}

// MARK: - Core Audio helpers

extension AudioTest {
    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func devices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids
    }

    static func name(of device: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else {
            return "?"
        }
        return value?.takeRetainedValue() as String? ?? "?"
    }

    static func outputChannels(of device: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let blob = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { blob.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, blob) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            blob.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultOutput() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    static func nominalRate(of device: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = 0.0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return value
    }

    @discardableResult
    static func setNominalRate(_ rate: Double, on device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        return AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }

    /// Whether the machine is being held awake on CoreEQ's behalf.
    ///
    /// Only meaningful on real hardware. A virtual device does not always make
    /// coreaudiod raise an assertion at all, so this is checked against a
    /// precondition rather than asserted blindly — see `sleepAssertionApplies`.
    static func sleepAssertionHeld() -> Bool {
        shell("/usr/bin/pmset", ["-g", "assertions"]).contains("andreypudov.coreeq")
    }

    /// Whether anything at all is using the device.
    ///
    /// The direct signal for whether CoreEQ has let go: idling stops its IO
    /// proc, and a device nobody is running reports false. Unlike the sleep
    /// assertion this means the same thing on every device, real or virtual.
    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr
            && value != 0
    }

    @discardableResult
    static func shell(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Playing and capturing

extension AudioTest {
    /// A stereo WAV of the two test tones, written once and reused.
    static func writeToneFile() -> URL {
        let frames = Int(rate * toneSeconds)
        var samples = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let t = Double(frame) / rate
            samples[frame * 2] = Int16(amplitude * 32_767 * sin(2 * .pi * leftHz * t))
            samples[frame * 2 + 1] = Int16(amplitude * 32_767 * sin(2 * .pi * rightHz * t))
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(2))
        append(UInt32(rate))
        append(UInt32(rate) * 4)
        append(UInt16(4))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(payload)
        samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreeq-audio-test-tone.wav")
        try? data.write(to: url)
        return url
    }

    /// Plays the tone and reports what arrived at `device`'s input.
    ///
    /// The magnitude at each test frequency is accumulated per channel as the
    /// audio arrives — one complex multiply-add per sample, no storage — so a
    /// swapped or smeared channel shows up as energy at the wrong frequency
    /// rather than as a level that still looks plausible.
    static func measure(on device: AudioDeviceID, tone: URL) -> Measurement? {
        let channels = outputChannels(of: device)
        guard channels > 0 else { return nil }

        final class Accumulator: @unchecked Sendable {
            var leftReal: [Double]
            var leftImaginary: [Double]
            var rightReal: [Double]
            var rightImaginary: [Double]
            var square: [Double]
            var frames = 0
            /// Only the steady middle of the tone is integrated. Including the
            /// silence either side made the result depend on exactly when the
            /// player started, which drifted a whole decibel between runs — and
            /// a decibel of noise is the size of the differences being looked
            /// for.
            var accumulating = false
            let channels: Int
            init(channels: Int) {
                self.channels = channels
                leftReal = .init(repeating: 0, count: channels)
                leftImaginary = .init(repeating: 0, count: channels)
                rightReal = .init(repeating: 0, count: channels)
                rightImaginary = .init(repeating: 0, count: channels)
                square = .init(repeating: 0, count: channels)
            }
        }
        let accumulator = Accumulator(channels: channels)

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) {
            _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var base = 0
            for i in 0..<list.count {
                guard let data = list[i].mData?.assumingMemoryBound(to: Float.self) else {
                    continue
                }
                let bufferChannels = Int(list[i].mNumberChannels)
                guard bufferChannels > 0 else { continue }
                let frames =
                    Int(list[i].mDataByteSize) / (MemoryLayout<Float>.size * bufferChannels)
                guard accumulator.accumulating else { continue }
                for frame in 0..<frames {
                    let n = Double(accumulator.frames + frame)
                    let leftPhase = -2 * Double.pi * leftHz * n / rate
                    let rightPhase = -2 * Double.pi * rightHz * n / rate
                    for channel in 0..<bufferChannels {
                        let global = base + channel
                        guard global < accumulator.channels else { continue }
                        let x = Double(data[frame * bufferChannels + channel])
                        accumulator.leftReal[global] += x * cos(leftPhase)
                        accumulator.leftImaginary[global] += x * sin(leftPhase)
                        accumulator.rightReal[global] += x * cos(rightPhase)
                        accumulator.rightImaginary[global] += x * sin(rightPhase)
                        accumulator.square[global] += x * x
                    }
                }
                if i == list.count - 1 { accumulator.frames += frames }
                base += bufferChannels
            }
        }
        guard status == noErr, let procID else { return nil }
        defer {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        AudioDeviceStart(device, procID)

        // Let the device settle before the tone, so the first buffers after a
        // resume are inside the measurement rather than before it.
        Thread.sleep(forTimeInterval: 0.4)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [tone.path]
        try? player.run()

        // A fixed window in the middle of the tone, clear of the player
        // starting and stopping.
        Thread.sleep(forTimeInterval: 0.7)
        accumulator.accumulating = true
        Thread.sleep(forTimeInterval: toneSeconds - 1.4)
        accumulator.accumulating = false

        player.waitUntilExit()

        let n = Double(max(accumulator.frames, 1))
        func magnitude(_ real: [Double], _ imaginary: [Double]) -> [Double] {
            (0..<channels).map { 2 * (real[$0] * real[$0] + imaginary[$0] * imaginary[$0]).squareRoot() / n }
        }
        return Measurement(
            atLeft: magnitude(accumulator.leftReal, accumulator.leftImaginary),
            atRight: magnitude(accumulator.rightReal, accumulator.rightImaginary),
            rms: (0..<channels).map { (accumulator.square[$0] / n).squareRoot() },
            channels: channels)
    }
}

// MARK: - The app under test

extension AudioTest {
    static let appPath = "build/Release/CoreEQ.app"

    static func isRunning() -> Bool {
        !shell("/usr/bin/pgrep", ["-x", "CoreEQ"]).trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    static func quitApp() {
        shell("/usr/bin/pkill", ["-x", "CoreEQ"])
        for _ in 0..<40 where isRunning() { Thread.sleep(forTimeInterval: 0.25) }
        Thread.sleep(forTimeInterval: 0.5)
    }

    static func launchApp() -> Bool {
        shell("/usr/bin/open", [appPath])
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if isRunning() { break }
        }
        // The engine builds its tap and aggregate after launch, and on a first
        // run it also has to prove the tap before it starts processing.
        Thread.sleep(forTimeInterval: 6)
        return isRunning()
    }

    /// Waits for the engine to let go of the device, which it does after
    /// `IdlePolicy.idleAfter` of silence.
    static func waitForIdle(_ device: AudioDeviceID, limit: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if !isRunningSomewhere(device) { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }
}

// MARK: - The run

extension AudioTest {
    static func run() -> Int32 {
        print("CoreEQ audio test\n")

        guard FileManager.default.fileExists(atPath: appPath) else {
            print("  build/Release/CoreEQ.app not found — run `make build` first.")
            return 2
        }
        guard let blackHole = devices().first(where: { name(of: $0).hasPrefix("BlackHole") }) else {
            print("  BlackHole is not installed. It is what makes this silent and exact:")
            print("  the tone is played into it and read straight back out.")
            print("  brew install blackhole-16ch")
            return 2
        }

        let deviceName = name(of: blackHole)
        let deviceChannels = outputChannels(of: blackHole)
        print("  capturing through \(deviceName) (\(deviceChannels) channels)\n")

        // Everything below changes the machine's audio settings. Whatever
        // happens, they go back.
        let originalOutput = defaultOutput()
        let originalRate = nominalRate(of: blackHole)
        let wasRunning = isRunning()
        defer {
            setNominalRate(originalRate, on: blackHole)
            setDefaultOutput(originalOutput)
            if wasRunning && !isRunning() { shell("/usr/bin/open", [appPath]) }
            print("\n  restored: output \(name(of: originalOutput)), \(Int(originalRate)) Hz")
        }

        setNominalRate(rate, on: blackHole)
        setDefaultOutput(blackHole)
        Thread.sleep(forTimeInterval: 1)
        let tone = writeToneFile()

        // --- Ground truth, with CoreEQ out of the way ---------------------
        quitApp()
        guard let baseline = measure(on: blackHole, tone: tone) else {
            print("  could not capture from \(deviceName)")
            return 2
        }
        print("Baseline, CoreEQ not running")
        note(
            String(
                format: "left tone %.1f dB on ch0, right tone %.1f dB on ch1",
                baseline.decibels(baseline.atLeft[0]), baseline.decibels(baseline.atRight[1])))
        check(
            "the harness itself hears the test signal",
            baseline.decibels(baseline.atLeft[0]) > -40 && baseline.decibels(baseline.atRight[1]) > -40,
            "if this fails, nothing below means anything")
        print("")

        // --- With CoreEQ in the path --------------------------------------
        guard launchApp() else {
            print("  CoreEQ did not launch")
            return 2
        }
        guard let processed = measure(on: blackHole, tone: tone) else {
            print("  could not capture with CoreEQ running")
            return 2
        }

        print("With CoreEQ running")
        let leftGain = processed.decibels(processed.atLeft[0]) - baseline.decibels(baseline.atLeft[0])
        let rightGain =
            processed.decibels(processed.atRight[1]) - baseline.decibels(baseline.atRight[1])
        note(String(format: "gain applied: %+.2f dB at %.0f Hz, %+.2f dB at %.0f Hz",
                    leftGain, leftHz, rightGain, rightHz))

        // Audio arrives at all. Three shipped defects made the Mac silent while
        // every layer reported success; each of them fails here.
        check(
            "audio reaches the device",
            processed.decibels(processed.atLeft[0]) > -60
                && processed.decibels(processed.atRight[1]) > -60,
            String(format: "ch0 %.1f dB, ch1 %.1f dB",
                   processed.decibels(processed.atLeft[0]),
                   processed.decibels(processed.atRight[1])))

        // Each tone comes back on the channel it was played into. The
        // multichannel defect put audio somewhere else entirely, which sounds
        // broken but reports fine.
        let leftLeak = processed.decibels(processed.atLeft[1]) - processed.decibels(processed.atLeft[0])
        let rightLeak =
            processed.decibels(processed.atRight[0]) - processed.decibels(processed.atRight[1])
        check(
            "channels are not swapped or smeared",
            leftLeak < -30 && rightLeak < -30,
            String(format: "crosstalk %.0f dB and %.0f dB", leftLeak, rightLeak))

        // Nothing lands in a channel the tap never fed. On a 16 channel device
        // this is the multichannel regression guard.
        if deviceChannels > 2 {
            let strays = (2..<deviceChannels).filter { processed.decibels(processed.rms[$0]) > -70 }
            check(
                "channels beyond the tap stay silent",
                strays.isEmpty,
                strays.isEmpty
                    ? "\(deviceChannels - 2) channels checked"
                    : "audio found on \(strays.map(String.init).joined(separator: ", "))")
        }

        // The tap mutes the original and CoreEQ writes its own copy. If the
        // muting ever stopped working both would play, and the level would jump.
        check(
            "the original is muted, not played alongside",
            abs(leftGain) < 24 && abs(rightGain) < 24,
            String(format: "%+.1f dB / %+.1f dB against baseline", leftGain, rightGain))

        // Whether this machine raises a sleep assertion for this device at all.
        // Recorded while audio is definitely flowing, so the idle checks below
        // know whether that signal means anything here.
        let assertionApplies = sleepAssertionHeld()

        print("")
        return checkIdleCycle(
            blackHole: blackHole, tone: tone, processed: processed,
            assertionApplies: assertionApplies)
    }
}

extension AudioTest {
    /// The behaviour added in 1.8: the device is released when nothing plays,
    /// and taken back when something does.
    ///
    /// The audio after a resume is compared against the audio before it rather
    /// than against an absolute figure, which makes the check exact without
    /// knowing anything about the user's preset.
    static func checkIdleCycle(
        blackHole: AudioDeviceID, tone: URL, processed: Measurement, assertionApplies: Bool
    ) -> Int32 {
        print("Releasing the device when nothing is playing")

        let released = waitForIdle(blackHole, limit: 45)
        check(
            "the device is let go after silence",
            released,
            released ? "" : "still in use after 45 s — the Mac will not sleep")

        // The moment the whole feature is for: the machine is no longer being
        // held awake. Checked here rather than after the resume, because this
        // is the only point at which it should be false.
        if !assertionApplies {
            skip(
                "the Mac is no longer held awake",
                "\(name(of: blackHole)) raised no assertion; check this on real hardware")
        } else if released {
            check("the Mac is no longer held awake", !sleepAssertionHeld())
        } else {
            check("the Mac is no longer held awake", false, "the device was never released")
        }

        guard let resumed = measure(on: blackHole, tone: tone) else {
            check("audio comes back after idling", false, "could not capture")
            return failures > 0 ? 1 : 0
        }

        check(
            "audio comes back after idling",
            resumed.decibels(resumed.atLeft[0]) > -60
                && resumed.decibels(resumed.atRight[1]) > -60,
            String(format: "ch0 %.1f dB, ch1 %.1f dB",
                   resumed.decibels(resumed.atLeft[0]), resumed.decibels(resumed.atRight[1])))

        let leftDrift = resumed.decibels(resumed.atLeft[0]) - processed.decibels(processed.atLeft[0])
        let rightDrift =
            resumed.decibels(resumed.atRight[1]) - processed.decibels(processed.atRight[1])
        check(
            "the sound is unchanged by an idle cycle",
            abs(leftDrift) < 0.5 && abs(rightDrift) < 0.5,
            String(format: "%+.2f dB / %+.2f dB", leftDrift, rightDrift))

        check(
            "playing again takes the device back",
            isRunningSomewhere(blackHole),
            "")


        print("")
        return failures > 0 ? 1 : 0
    }
}

@main
struct AudioTestCommand {
    static func main() {
        let code = AudioTest.run()
        print("\n\(AudioTest.checks - AudioTest.failures)/\(AudioTest.checks) checks passed")
        print(AudioTest.failures > 0 ? "\nAUDIO TEST FAILED" : "\nAUDIO TEST PASSED")
        exit(code)
    }
}
