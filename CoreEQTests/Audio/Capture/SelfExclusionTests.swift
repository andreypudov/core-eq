import Foundation
import Testing

/// Whether the engine may build a tap that leaves CoreEQ out.
///
/// The defect this guards passed silently: a lookup that "succeeded" with
/// object 0 was excluded as though it were CoreEQ, which excludes nothing, and
/// the tap heard CoreEQ's own output.
struct SelfExclusionTests {
    @Test func aRealProcessObjectIsExcluded() {
        #expect(SelfExclusion.validated(145) == 145)
    }

    /// Measured: Core Audio answers an unknown PID with status 0 and object 0.
    @Test func theUnknownObjectIsRefused() {
        #expect(SelfExclusion.validated(SelfExclusion.unknownObject) == nil)
    }

    @Test func aFailedLookupIsRefused() {
        #expect(SelfExclusion.validated(nil) == nil)
    }
}
