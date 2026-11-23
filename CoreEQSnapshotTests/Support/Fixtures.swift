import AppKit
import Foundation

@testable import CoreEQ

/// Fixed state for the window: the same preset, the same output devices, and
/// the same spectrum on every machine and every run.
@MainActor
struct Fixtures {
    let settings = SettingsStore(defaults: InMemoryDefaults())
    let manager: ProfileManager
    let engine: AudioEngine
    let outputs = AudioDeviceList(
        fixed: [
            AudioDevices.Device(id: 1, name: "MacBook Pro Speakers", symbolName: "laptopcomputer"),
            AudioDevices.Device(id: 2, name: "External Headphones", symbolName: "headphones"),
        ],
        defaultDeviceID: 1)
    let spectrum: SpectrumAnalyzer

    /// What `@AppStorage` reads in the views, so the user's own defaults (the
    /// host is the real app) never reach a snapshot.
    let viewDefaults = InMemoryDefaults()

    init(preset: String = "Bass Booster") {
        manager = ProfileManager(settings: settings)
        manager.setActiveProfile(name: preset)
        engine = AudioEngine(settings: settings)
        engine.showStatusForSnapshot(.running(deviceName: "MacBook Pro Speakers"))
        spectrum = Self.settledSpectrum()
    }

    /// An analyzer that has listened to one second of a fixed signal: a chord
    /// over pink-ish noise, the same samples every time.
    static func settledSpectrum() -> SpectrumAnalyzer {
        let rate = 48_000.0
        let buffer = SpectrumAudioBuffer(capacity: 8_192)
        let analyzer = SpectrumAnalyzer(buffer: buffer, sampleRate: { rate })

        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var b0 = 0.0
        var b1 = 0.0
        var b2 = 0.0
        let partials = [110.0, 164.81].flatMap { root in
            (1...12).map { (frequency: root * Double($0), amplitude: 0.08 / Double($0)) }
        }
        let samples: [Float] = (0..<Int(rate)).map { i in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let white = Double(state >> 11) / Double(1 << 53) * 2 - 1
            b0 = 0.997 * b0 + white * 0.029
            b1 = 0.985 * b1 + white * 0.032
            b2 = 0.950 * b2 + white * 0.048
            let t = Double(i) / rate
            let tones = partials.reduce(0) { $0 + $1.amplitude * sin(2 * .pi * $1.frequency * t) }
            return Float((b0 + b1 + b2) * 0.4 + tones)
        }

        let chunk = 1_024
        for start in stride(from: 0, to: samples.count, by: chunk) {
            let slice = Array(samples[start..<min(start + chunk, samples.count)])
            slice.withUnsafeBufferPointer { pointer in
                buffer.write(interleaved: pointer.baseAddress!, frames: slice.count, channels: 1)
            }
            analyzer.analyze()
        }
        return analyzer
    }
}

/// A `UserDefaults` that lives only in memory. A copy of the one in
/// `CoreEQTests/Support`, which this target does not compile.
final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }
    override func string(forKey defaultName: String) -> String? { storage[defaultName] as? String }
    override func array(forKey defaultName: String) -> [Any]? { storage[defaultName] as? [Any] }
    override func data(forKey defaultName: String) -> Data? { storage[defaultName] as? Data }
    override func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }
    override func double(forKey defaultName: String) -> Double {
        storage[defaultName] as? Double ?? 0
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}
