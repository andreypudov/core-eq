import AppKit
import Foundation
import Testing

@testable import CoreEQ

@MainActor
struct ProfileManagerImportExportTests {
    private func makeManager() -> (ProfileManager, UserDefaults) {
        let name = "test.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let store = SettingsStore(defaults: defaults)
        let manager = ProfileManager(settings: store)
        return (manager, defaults)
    }

    @Test func importProfileFromTextCreatesAndActivatesUserPreset() throws {
        let (manager, defaults) = makeManager()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

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
        let (manager, defaults) = makeManager()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

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
        let (manager, defaults) = makeManager()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
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
        let (manager, defaults) = makeManager()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ARTTI T10 ParametricEq.txt")
        let content = "Preamp: -2.99 dB\nFilter 1: ON LSC Fc 105.0 Hz Gain -1.9 dB Q 0.70\n"
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let importedName = try manager.importProfile(from: tempURL)
        #expect(importedName == "ARTTI T10")
        #expect(manager.activeProfileName == "ARTTI T10")
        #expect(manager.currentPreamp == -2.99)
    }
}
