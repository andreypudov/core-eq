import AppKit
import Foundation
import Testing

@testable import CoreEQ

/// A `UserDefaults` that lives only in memory.
///
/// A per-test `UserDefaults(suiteName:)` is the obvious isolation, but it leaks:
/// cfprefsd persists each written suite to `~/Library/Preferences`
/// asynchronously, and can flush it back to disk *after*
/// `removePersistentDomain(forName:)` and even after the backing file has been
/// deleted. Cleanup therefore cannot be made reliable — one empty plist per
/// written suite is recreated every run. Keeping the store entirely in memory
/// means there is never a plist to clean up.
private final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }

    override func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    override func array(forKey defaultName: String) -> [Any]? {
        storage[defaultName] as? [Any]
    }

    override func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            storage[defaultName] = value
        } else {
            storage.removeValue(forKey: defaultName)
        }
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}

@MainActor
struct ProfileManagerImportExportTests {
    private func makeManager() -> (manager: ProfileManager, defaults: UserDefaults) {
        let defaults = InMemoryDefaults()
        let store = SettingsStore(defaults: defaults)
        let manager = ProfileManager(settings: store)
        return (manager, defaults)
    }

    @Test func importProfileFromTextCreatesAndActivatesUserPreset() throws {
        let (manager, defaults) = makeManager()

        let text = """
            Preamp: -4.0 dB
            Filter 1: ON PK Fc 1500 Hz Gain 3.5 dB Q 1.50
            """

        let importedName = try manager.importProfile(from: text, name: "IEM Target")
        #expect(importedName == "IEM Target")
        #expect(manager.activeProfileName == "IEM Target")
        #expect(manager.canEditProfile(named: "IEM Target"))
        #expect(manager.currentPreamp == -4.0)

        let freeFilters = manager.freeFilters
        #expect(freeFilters.count == 1)
        #expect(freeFilters[0].frequency == 1500)
        #expect(freeFilters[0].gain == 3.5)

        // Verify persistence in SettingsStore
        let storedManager = ProfileManager(settings: SettingsStore(defaults: defaults))
        #expect(storedManager.profile(named: "IEM Target") != nil)
    }

    @Test func exportProfileToEqualizerAPOFormat() throws {
        let (manager, _) = makeManager()

        let text = """
            Preamp: -2.0 dB
            Filter 1: ON LSC Fc 100 Hz Gain 4.0 dB Q 0.70
            """
        let name = try manager.importProfile(from: text, name: "Export Test")
        let exported = try manager.exportProfileToEqualizerAPO(named: name)

        #expect(exported.contains("Preamp: -2.0 dB"))
        #expect(exported.contains("LSC Fc 100 Hz Gain 4.0 dB Q 0.70"))
    }

    @Test func previewDoesNotPersistOrActivateUntilCommit() throws {
        let (manager, _) = makeManager()
        let original = manager.activeProfileName
        let preview = try manager.previewImport(
            from: "Preamp: -3.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00",
            name: "Preview Test")

        #expect(manager.profile(named: "Preview Test") == nil)
        #expect(manager.activeProfileName == original)

        let committed = manager.commitImport(preview)
        #expect(committed == "Preview Test")
        #expect(manager.profile(named: committed) != nil)
        #expect(manager.activeProfileName == committed)
    }

    @Test func cleanPresetNameStripsCommonAutoEQAndAPOSuffixes() {
        #expect(ProfileManager.cleanPresetName(from: "ARTTI T10 ParametricEq") == "ARTTI T10")
        #expect(
            ProfileManager.cleanPresetName(from: "Sennheiser HD 600 ParametricEQ")
                == "Sennheiser HD 600")
        #expect(
            ProfileManager.cleanPresetName(from: "Moondrop Chu II EqualizerAPO")
                == "Moondrop Chu II")
        #expect(
            ProfileManager.cleanPresetName(from: "Sony WH-1000XM4 GraphicEq") == "Sony WH-1000XM4")
        #expect(ProfileManager.cleanPresetName(from: "Custom Profile Preset") == "Custom Profile")
        #expect(ProfileManager.cleanPresetName(from: "Just A Name") == "Just A Name")
        #expect(ProfileManager.cleanPresetName(from: "   ") == "Imported Preset")
    }

    @Test func importProfileFromURLCleansFilename() throws {
        let (manager, _) = makeManager()

        // A per-run directory keeps the file name unique for parallel runs while
        // leaving the stem itself untouched, so what `cleanPresetName` sees is
        // still "ARTTI T10 ParametricEq".
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tempURL = directory.appendingPathComponent("ARTTI T10 ParametricEq.txt")
        let content = "Preamp: -2.99 dB\nFilter 1: ON LSC Fc 105.0 Hz Gain -1.9 dB Q 0.70\n"
        try content.write(to: tempURL, atomically: true, encoding: .utf8)

        let importedName = try manager.importProfile(from: tempURL)
        #expect(importedName == "ARTTI T10")
        #expect(manager.activeProfileName == "ARTTI T10")
        #expect(manager.currentPreamp == -2.99)
    }

    @Test func previewFilterCountExcludesLadderBands() throws {
        let (manager, _) = makeManager()

        let preview = try manager.previewImport(
            from: "Preamp: -3.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00",
            name: "Count Test")
        #expect(preview.filterCount == 1)
        #expect(preview.droppedFilterCount == 0)
        #expect(preview.unparsedLines.isEmpty)
    }

    @Test func previewCarriesDroppedFiltersAndUnparsedLines() throws {
        let (manager, _) = makeManager()

        var lines = ["Preamp: -2.0 dB", "GraphicEQ: 10 -20 30"]
        for i in 1...20 {
            lines.append("Filter \(i): ON PK Fc \(100 * i) Hz Gain \(Double(i % 10)) dB Q 1.0")
        }
        let preview = try manager.previewImport(
            from: lines.joined(separator: "\n"), name: "Trim Test")

        #expect(preview.filterCount == BuiltInProfiles.maxFreeFilters)
        #expect(preview.droppedFilterCount == 4)
        #expect(preview.unparsedLines == ["GraphicEQ: 10 -20 30"])
    }
}
