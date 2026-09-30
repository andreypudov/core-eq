import Foundation
import Testing

@testable import CoreEQ

@MainActor
struct ProfileManagerImportExportTests {
    private func makeManager() -> (manager: ProfileManager, defaults: UserDefaults) {
        let defaults = InMemoryDefaults()
        let store = SettingsStore(defaults: defaults)
        let manager = ProfileManager(settings: store)
        return (manager, defaults)
    }

    /// Previews and commits, as the sidebar's Import dialog does.
    private func importText(
        _ text: String, name: String? = nil, into manager: ProfileManager
    ) throws -> String {
        manager.commitImport(try manager.previewImport(text: text, suggestedName: name))
    }

    @Test func importProfileFromTextCreatesAndActivatesUserPreset() throws {
        let (manager, defaults) = makeManager()

        let text = """
            Preamp: -4.0 dB
            Filter 1: ON PK Fc 1500 Hz Gain 3.5 dB Q 1.50
            """

        let importedName = try importText(text, name: "IEM Target", into: manager)
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
        let name = try importText(text, name: "Export Test", into: manager)
        let exported = try manager.exportProfileToEqualizerAPO(named: name)

        #expect(exported.contains("Preamp: -2.0 dB"))
        #expect(exported.contains("LSC Fc 100.0 Hz Gain 4.0 dB Q 0.70"))
    }

    @Test func exportOfActivePresetWritesUnsavedEdits() throws {
        let (manager, _) = makeManager()
        let name = try importText(
            "Preamp: -2.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00", name: "Edited",
            into: manager)

        let filterID = try #require(manager.freeFilters.first).id
        manager.setFilterGain(-3.5, id: filterID)
        manager.setPreamp(-6.0)
        #expect(manager.isModified)

        let exported = try manager.exportProfileToEqualizerAPO(named: name)
        #expect(exported.contains("Preamp: -6.0 dB"))
        #expect(exported.contains("PK Fc 1000.0 Hz Gain -3.5 dB"))
    }

    @Test func exportOfActivePresetIncludesQuickEQTone() throws {
        let (manager, _) = makeManager()
        let name = manager.activeProfileName
        manager.setTone(bass: 4)

        let json = try manager.exportProfileToJSON(named: name)
        let exported = try JSONDecoder().decode(EQProfile.self, from: Data(json.utf8))
        #expect(exported.filters == manager.currentFilters)
        #expect(exported.preamp == manager.currentPreamp)
        #expect(exported.autoGain == manager.isAutoGain)
    }

    @Test func exportOfInactivePresetWritesSavedState() throws {
        let (manager, _) = makeManager()
        let saved = try importText(
            "Preamp: -2.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00", name: "Saved",
            into: manager)
        manager.setPreamp(-6.0)

        // Switching away discards the unsaved trim, so "Saved" is back to what
        // it was imported with.
        manager.setActiveProfile(name: BuiltInProfiles.defaultProfileName)
        manager.setTone(bass: 4)

        let exported = try manager.exportProfileToEqualizerAPO(named: saved)
        #expect(exported.contains("Preamp: -2.0 dB"))
        #expect(exported.contains("PK Fc 1000.0 Hz Gain 2.0 dB"))
    }

    @Test func previewDoesNotPersistOrActivateUntilCommit() throws {
        let (manager, _) = makeManager()
        let original = manager.activeProfileName
        let preview = try manager.previewImport(
            text: "Preamp: -3.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00",
            suggestedName: "Preview Test")

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

        let importedName = manager.commitImport(try manager.previewImport(fileAt: tempURL))
        #expect(importedName == "ARTTI T10")
        #expect(manager.activeProfileName == "ARTTI T10")
        #expect(manager.currentPreamp == -2.99)
    }

    @Test func previewFilterCountExcludesLadderBands() throws {
        let (manager, _) = makeManager()

        let preview = try manager.previewImport(
            text: "Preamp: -3.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00",
            suggestedName: "Count Test")
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
            text: lines.joined(separator: "\n"), suggestedName: "Trim Test")

        #expect(preview.filterCount == BuiltInProfiles.maxFreeFilters)
        #expect(preview.droppedFilterCount == 4)
        #expect(preview.unparsedLines == ["GraphicEQ: 10 -20 30"])
    }

    @Test func unnamedTextImportLandsInRename() throws {
        let (manager, _) = makeManager()
        let preview = try manager.previewImport(
            text: "Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00")
        #expect(preview.needsName)

        let stored = manager.commitImport(preview)
        #expect(stored == ProfileManager.untitledImportName)
        #expect(manager.profileAwaitingRename == stored)
    }

    @Test func namedImportDoesNotAskForAName() throws {
        let (manager, _) = makeManager()
        let preview = try manager.previewImport(
            text: "Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00", suggestedName: "HD 600")
        #expect(!preview.needsName)

        manager.commitImport(preview)
        #expect(manager.profileAwaitingRename == nil)
    }

    @Test func coreEQTextCarriesItsOwnName() throws {
        let (manager, _) = makeManager()
        let json = try ParametricEQSerializer.serializeToCoreEQJSON(
            EQProfile(name: "Shared", filters: BuiltInProfiles.emptyBandChain()))

        let preview = try manager.previewImport(text: json)
        #expect(preview.name == "Shared")
        #expect(!preview.needsName)
    }

    @Test func previewReportsAdjustedValues() throws {
        let (manager, _) = makeManager()
        let preview = try manager.previewImport(
            text: "Preamp: -20.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 18.0 dB Q 1.00",
            suggestedName: "Loud")
        #expect(preview.adjustedValueCount == 2)
    }

    @Test func oversizedFileIsRejectedBeforeReading() throws {
        let (manager, _) = makeManager()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: ParametricEQParser.maxFileSize + 1).write(to: url)

        #expect(throws: ParametricEQParser.ParseError.fileTooLarge) {
            try manager.previewImport(fileAt: url)
        }
    }

    @Test func exportOfMissingPresetSaysSo() {
        let (manager, _) = makeManager()
        #expect(throws: ProfileManager.ExportError.presetNotFound("Gone")) {
            try manager.exportProfileToEqualizerAPO(named: "Gone")
        }
    }

    @Test func fileImportReadsUTF16AndNamesItAfterTheFile() throws {
        let (manager, _) = makeManager()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // What Notepad saves as "Unicode": UTF-16 LE with a byte-order mark.
        let url = directory.appendingPathComponent("Sennheiser HD 600 ParametricEQ.txt")
        var data = Data([0xFF, 0xFE])
        data.append(
            "Preamp: -6.4 dB\r\nFilter 1: ON PK Fc 28 Hz Gain 6.2 dB Q 2.10\r\n".data(
                using: .utf16LittleEndian)!)
        try data.write(to: url)

        let preview = try manager.previewImport(fileAt: url)
        #expect(preview.name == "Sennheiser HD 600")
        #expect(preview.preamp == -6.4)
        #expect(preview.filterCount == 1)
    }

    @Test func missingFileReportsAnErrorAndAddsNothing() {
        let (manager, _) = makeManager()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(UUID().uuidString).txt")

        #expect(throws: (any Error).self) {
            try manager.previewImport(fileAt: url)
        }
        #expect(manager.library.user.isEmpty)
    }

    @Test func importTakingAnExistingNameGetsASuffix() throws {
        let (manager, _) = makeManager()
        let stored = try importText(
            "Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00", name: "Flat", into: manager)

        #expect(stored == "Flat 2")
        #expect(manager.profile(named: "Flat")?.isBuiltIn == true)
    }

    @Test func secondUnnamedImportRenamesTheNewOne() throws {
        let (manager, _) = makeManager()
        let text = "Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00"
        manager.commitImport(try manager.previewImport(text: text))
        manager.profileAwaitingRename = nil

        let second = manager.commitImport(try manager.previewImport(text: text))
        #expect(second == "\(ProfileManager.untitledImportName) 2")
        #expect(manager.profileAwaitingRename == second)
    }
}
