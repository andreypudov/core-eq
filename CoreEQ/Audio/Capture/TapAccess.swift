import Foundation

/// What CoreEQ believes about the System Audio Recording permission.
///
/// TCC's own answer (`AudioCapturePermission`) is the source when it can be
/// asked: it is immediate, and it can tell "never asked" from "refused". When
/// the private entry point is unavailable, the capture proof and tap creation
/// are all there is, as before it existed.
///
/// A yes from TCC is believed even when the tap then proves silent. That case
/// was designed for — an update leaving an entry in System Settings that no
/// longer covers the new build — and measured not to happen: an ad-hoc rebuild
/// reads as never asked. Silence under a yes is more likely a player holding
/// the device open while sending nothing, so the engine reports it as an engine
/// problem rather than accusing the permission.
///
/// Notably *not* derived from the engine failing. The engine has failures that
/// happen before a tap is ever attempted, and reading those as a refusal tells
/// someone their permission is missing when it is granted.
///
/// A top-level type rather than a member of `AudioEngine` so it can be rendered
/// and tested without dragging Core Audio in behind it.
enum TapAccess: Equatable {
    /// TCC says yes, or — without TCC to ask — a tap was created.
    case granted
    /// TCC has never asked. The engine waits for CoreEQ to explain and ask.
    case notDetermined
    /// TCC says no, or — without TCC to ask — the proof says nothing arrives.
    case denied
    /// Nothing to go on yet: TCC cannot be asked and no tap has been tried.
    case unknown

    /// What to believe, from what TCC says and what the tap showed.
    ///
    /// - Parameters:
    ///   - tcc: TCC's answer, or nil when it cannot be asked.
    ///   - proof: the capture proof's latest verdict, or nil when none has run.
    /// - Returns: what the engine and every surface should act on.
    ///
    /// The proof only decides when TCC cannot be asked. And nothing here
    /// touches the proof's *muting* — that is `captureProven` in the engine, so
    /// a yes from TCC never mutes a tap that has not delivered.
    static func resolve(
        tcc: AudioCapturePermission.Answer?, proof: CaptureProof.Verdict?
    ) -> TapAccess {
        switch (tcc, proof) {
        case (.granted, _): return .granted
        case (.denied, _): return .denied
        case (.notDetermined, _): return .notDetermined
        case (nil, .proven): return .granted
        case (nil, .notCapturing): return .denied
        case (nil, .waiting), (nil, nil): return .unknown
        }
    }

    /// Whether there is something for the user to do, and so a screen saying
    /// what.
    var needsAction: Bool {
        switch self {
        case .notDetermined, .denied: return true
        case .granted, .unknown: return false
        }
    }

    /// How the diagnostics report says it. "Not determined" rather than
    /// "unknown", because the report is read by someone deciding whether the
    /// permission is the problem, and the honest answer is that CoreEQ has not
    /// found out this session.
    var reportDescription: String {
        switch self {
        case .granted: return "granted"
        case .notDetermined: return "not asked yet"
        case .denied: return "REFUSED"
        case .unknown: return "not determined this session"
        }
    }
}
