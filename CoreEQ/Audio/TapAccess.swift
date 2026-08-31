import Foundation

/// What the engine has observed about System Audio Recording permission.
///
/// There is no API that answers "may I tap system audio", so the only ground
/// truth is whether a tap was created. This records that observation rather
/// than deriving it from whether the engine is running — the engine has
/// failures that happen before a tap is ever attempted, and reading those as a
/// refusal tells someone their permission is missing when it is granted.
///
/// A top-level type rather than a member of `AudioEngine` so it can be rendered
/// and tested without dragging Core Audio in behind it.
enum TapAccess: Equatable {
    /// A tap was created. Ground truth, and the only way to know.
    case granted
    /// Creating the tap was refused.
    case denied
    /// The engine has not tried yet, or failed before reaching the tap.
    case unknown

    /// How the diagnostics report says it. "Not determined" rather than
    /// "unknown", because the report is read by someone deciding whether the
    /// permission is the problem, and the honest answer is that CoreEQ has not
    /// found out this session.
    var reportDescription: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "REFUSED"
        case .unknown: return "not determined this session"
        }
    }
}
