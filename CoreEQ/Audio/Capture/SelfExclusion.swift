import Foundation

/// Whether the lookup of CoreEQ's own audio process produced something a tap
/// can actually exclude.
///
/// Every tap has to leave CoreEQ out, or it captures what CoreEQ has just
/// played and feeds it back in — the loop the roadmap records under *Echo and
/// doubled audio*, where a harness that tapped its own output compounded from
/// a 0.4 peak to 71.
///
/// The lookup can fail in two ways, and only one of them looks like failure.
/// The call can return an error; or it can succeed and hand back
/// `kAudioObjectUnknown` for a process Core Audio does not know — measured: a
/// PID with no audio client comes back as status 0, object 0. Excluding object
/// 0 excludes nothing, so before this the engine built a tap that heard itself
/// and nothing said so.
///
/// Pure, and its own type, because the engine cannot be reached by a test and
/// this is the part that was wrong.
enum SelfExclusion {
    /// `kAudioObjectUnknown`, spelled out so this file needs no Core Audio.
    static let unknownObject: UInt32 = 0

    /// The object to exclude, or nil when the lookup gave nothing usable and
    /// the engine must not build a tap.
    static func validated(_ lookup: UInt32?) -> UInt32? {
        guard let lookup, lookup != unknownObject else { return nil }
        return lookup
    }
}
