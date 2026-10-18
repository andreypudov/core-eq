import Foundation
import Testing

/// What a CoreEQ 1.9.2 install left on disk still loads, unchanged.
///
/// The JSON below is not written by hand: it is what 1.9.2's own `EQProfile`
/// and `DeviceEQState` encoded, built from that tag's sources. An update that
/// silently dropped someone's presets, or put every device back to Flat, is
/// the regression this catches — and `try?` decoding means it would happen
/// without an error anywhere.
@MainActor struct UpgradeFrom192Tests {
    /// One user preset: two edited bands, a low shelf, and
    /// a switched-off high pass, with a held trim.
    static let userProfiles = #"""
        [{"autoGain":false,"filters":[{"band":0,"colorIndex":0,"frequency":32,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":1,"colorIndex":0,"frequency":64,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":2,"colorIndex":0,"frequency":125,"gain":4.5,"isEnabled":true,"kind":"bell","q":1.41},{"band":3,"colorIndex":0,"frequency":250,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":4,"colorIndex":0,"frequency":500,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":5,"colorIndex":0,"frequency":1000,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":6,"colorIndex":0,"frequency":2000,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":7,"colorIndex":0,"frequency":4000,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":8,"colorIndex":0,"frequency":8000,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":9,"colorIndex":0,"frequency":16000,"gain":-2,"isEnabled":true,"kind":"bell","q":1.41},{"band":10,"colorIndex":0,"frequency":20000,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"colorIndex":0,"frequency":105,"gain":6,"isEnabled":true,"kind":"lowShelf","q":0.7},{"colorIndex":1,"frequency":30,"gain":0,"isEnabled":false,"kind":"highPass","q":0.71}],"name":"Mine","preamp":-3}]
        """#

    /// The built-in speakers, with the user's preset live in slot B, and Rock
    /// waiting in slot A with the quick tone controls moved.
    static let deviceStates = #"""
        {"BuiltInSpeakerDevice":{"alternate":{"autoGain":true,"preamp":0,"profileName":"Rock","tone":[1,0,-1]},"autoGain":false,"filters":[{"band":0,"colorIndex":0,"frequency":32,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":1,"colorIndex":0,"frequency":64,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":2,"colorIndex":0,"frequency":125,"gain":4.5,"isEnabled":true,"kind":"bell","q":1.41},{"band":3,"colorIndex":0,"frequency":250,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":4,"colorIndex":0,"frequency":500,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":5,"colorIndex":0,"frequency":1000,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":6,"colorIndex":0,"frequency":2000,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":7,"colorIndex":0,"frequency":4000,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":8,"colorIndex":0,"frequency":8000,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"band":9,"colorIndex":0,"frequency":16000,"gain":-2,"isEnabled":true,"kind":"bell","q":1.41},{"band":10,"colorIndex":0,"frequency":20000,"gain":0,"isEnabled":true,"kind":"bell","q":1.41},{"colorIndex":0,"frequency":105,"gain":6,"isEnabled":true,"kind":"lowShelf","q":0.7},{"colorIndex":1,"frequency":30,"gain":0,"isEnabled":false,"kind":"highPass","q":0.71}],"liveSlot":"b","preamp":-3,"profileName":"Mine"}}
        """#

    private let settings: SettingsStore

    init() {
        let defaults = InMemoryDefaults()
        defaults.set(Data(Self.userProfiles.utf8), forKey: "userProfiles")
        defaults.set(Data(Self.deviceStates.utf8), forKey: "deviceStates")
        defaults.set("Mine", forKey: "activeProfileName")
        settings = SettingsStore(defaults: defaults)
    }

    @Test func userPresetsLoadUnchanged() throws {
        let mine = try #require(settings.userProfiles.first)
        #expect(settings.userProfiles.count == 1)
        #expect(mine.name == "Mine")
        #expect(mine.preamp == -3)
        #expect(!mine.autoGain)
        #expect(mine.filters.filter(\.isBand).map(\.gain) == [0, 0, 4.5, 0, 0, 0, 0, 0, 0, -2, 0])

        let free = mine.filters.filter { !$0.isBand }
        #expect(free.map(\.kind) == [.lowShelf, .highPass])
        #expect(free.map(\.frequency) == [105, 30])
        #expect(free.map(\.isEnabled) == [true, false])
    }

    @Test func eachDeviceComesBackAsItWasLeft() {
        let manager = ProfileManager(settings: settings, outputDeviceUID: "BuiltInSpeakerDevice")

        #expect(manager.activeProfileName == "Mine")
        #expect(manager.abSlot == .b)
        #expect(manager.currentPreamp == -3)
        #expect(!manager.isAutoGain)
        #expect(manager.tone == ProfileManager.ToneControls())
        #expect(manager.bandFilters.map(\.gain) == [0, 0, 4.5, 0, 0, 0, 0, 0, 0, -2, 0])
        #expect(manager.freeFilters.map(\.kind) == [.lowShelf, .highPass])
        #expect(!manager.isModified)

        manager.setSlot(.a)
        #expect(manager.activeProfileName == "Rock")
        #expect(manager.isAutoGain)
        #expect(manager.tone == ProfileManager.ToneControls(bass: 1, mid: 0, treble: -1))
    }
}
