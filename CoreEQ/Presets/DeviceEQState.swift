import Foundation

/// Everything CoreEQ remembers for one output device.
///
/// macOS keeps volume per device — switch to headphones and you get the level
/// you last set for headphones — and equalization has the same shape: the curve
/// that suits headphones is not the one that suits laptop speakers. So the
/// preset in effect, any unsaved edits to it, the output trim, and the Quick EQ
/// tone positions all belong to a device rather than to the application.
///
/// The preset *library* is deliberately not per device. Presets are a shared
/// collection; only which one is playing, and what has been changed about it,
/// follows the hardware.
struct DeviceEQState: Codable, Equatable {
    var profileName: String
    /// The working chain, or nil when it still matches the preset.
    var filters: [EQFilter]?
    var preamp: Double
    /// `[bass, mid, treble]`, or nil when all three are centred.
    var tone: [Double]?

    init(profileName: String, filters: [EQFilter]? = nil, preamp: Double = 0, tone: [Double]? = nil) {
        self.profileName = profileName
        self.filters = filters
        self.preamp = preamp
        self.tone = tone
    }
}
