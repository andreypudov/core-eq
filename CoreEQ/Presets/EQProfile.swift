import Foundation

/// A named set of band parameters.
struct EQProfile: Codable, Equatable, Identifiable {
    var name: String
    var bands: [EQBand]

    /// Built-in profiles ship with CoreEQ and can't be renamed, edited in place,
    /// or deleted. User profiles support the full set of sidebar actions.
    ///
    /// Deliberately outside `CodingKeys`: only user profiles are ever persisted,
    /// so a decoded profile is always a user profile.
    var isBuiltIn = false

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, bands
    }
}
