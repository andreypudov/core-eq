import Foundation

/// Asks macOS directly whether CoreEQ may capture system audio, and asks the
/// user when it has not been decided.
///
/// There is no public API for this. `AudioHardwareCreateProcessTap` succeeds
/// when the permission is refused and then delivers silence, so without this
/// the engine can only infer a refusal from audio playing and none arriving —
/// which takes six seconds, and on a quiet Mac never happens at all. It also
/// cannot tell "never asked" from "refused", and those want different screens.
///
/// So this uses TCC's own entry points, `TCCAccessPreflight` and
/// `TCCAccessRequest`, which are private. That is acceptable here for reasons
/// that each matter:
/// - CoreEQ is not distributed through the App Store, which would refuse it.
/// - The symbols are looked up at runtime, so a macOS that removes or renames
///   them leaves `preflight()` returning nil rather than a crash at launch.
/// - Nil puts the engine back on the inference it used before this existed,
///   and the capture proof runs either way, so a wrong answer here can delay
///   equalizing but cannot mute the Mac.
///
/// Only the thin layer that cannot be tested. What to *believe* from an answer
/// is `TapAccess.resolve`.
///
/// Built without the `COREEQ_TCC_SPI` condition (`make build
/// XCODE_FLAGS=COREEQ_TCC_SPI=NO`), the private names are not in the binary at
/// all and this reports itself unavailable — exactly what a macOS that removed
/// them would do. That is how the fallback gets exercised on a Mac where the
/// entry points exist, and what a distributor that scans for private API
/// would need.
enum AudioCapturePermission {

    /// What TCC has recorded for CoreEQ.
    enum Answer: Equatable {
        case granted
        case denied
        /// Never asked, or the entry was reset. Asking now shows the prompt.
        case notDetermined
    }

    /// The service as TCC names it.
    static let service = "kTCCServiceAudioCapture"

    /// What TCC currently says, or nil when the private entry point is not
    /// there to ask.
    ///
    /// A cheap XPC to `tccd`, so it can be polled while the user is in the
    /// middle of changing the answer.
    static func preflight() -> Answer? {
        guard let preflight = Symbols.shared.preflight else { return nil }
        return answer(fromPreflight: preflight(service as CFString, nil))
    }

    /// Whether `preflight()` can answer at all.
    static var isAvailable: Bool { Symbols.shared.preflight != nil }

    /// TCC's preflight result, as an answer.
    ///
    /// 0 and 1 are the only values with a fixed meaning; anything else has been
    /// seen to mean "not determined", and treating an unexpected value that way
    /// is the safe reading — it offers the prompt rather than claiming either
    /// answer.
    static func answer(fromPreflight result: Int) -> Answer {
        switch result {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt if the answer is not determined, and reports the
    /// answer either way. Delivered on the main actor.
    ///
    /// Reports false without asking when the entry point is missing; the caller
    /// then falls back to creating a tap, which raises the same prompt as a side
    /// effect.
    static func request(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let request = Symbols.shared.request else {
            Task { @MainActor in completion(false) }
            return
        }
        // TCC calls back on its own queue, and everything the answer touches
        // belongs to the main actor.
        request(service as CFString, nil) { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    // MARK: - The private entry points

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction =
        @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) ->
        Void

    /// Resolved once. Each is optional on its own, so losing one degrades only
    /// what depends on it.
    private struct Symbols: @unchecked Sendable {
        static let shared = Symbols()

        let preflight: PreflightFunction?
        let request: RequestFunction?

        private init() {
            #if COREEQ_TCC_SPI
            (preflight, request) = Self.lookUp()
            #else
            (preflight, request) = (nil, nil)
            #endif
        }

        #if COREEQ_TCC_SPI
        private static func lookUp() -> (PreflightFunction?, RequestFunction?) {
            guard
                let handle = dlopen(
                    "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
            else { return (nil, nil) }
            let preflight = dlsym(handle, "TCCAccessPreflight").map {
                unsafeBitCast($0, to: PreflightFunction.self)
            }
            let request = dlsym(handle, "TCCAccessRequest").map {
                unsafeBitCast($0, to: RequestFunction.self)
            }
            return (preflight, request)
        }
        #endif
    }
}
