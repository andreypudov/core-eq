import CoreAudio
import Foundation
import Testing

/// Who holds an output device, and which hold is worth saying anything about.
///
/// The case this exists for: macOS moves the default output off a hogged device,
/// so by the time the audio path has rebuilt, the current output is not the
/// device being held and looks entirely healthy.
struct ExclusiveAccessTests {
    private let me: pid_t = 100
    private let player: pid_t = 200
    private let dac: AudioObjectID = 10
    private let speakers: AudioObjectID = 20

    private func hold(
        dacOwner: pid_t = -1, speakersOwner: pid_t = -1, output: AudioObjectID? = nil,
        previous: ExclusiveAccess.Hold? = nil, appName: String? = "Player"
    ) -> ExclusiveAccess.Hold? {
        ExclusiveAccess.currentHold(
            in: [
                .init(deviceID: speakers, deviceName: "Speakers", owner: speakersOwner),
                .init(deviceID: dac, deviceName: "DAC", owner: dacOwner),
            ],
            me: me, output: output, previous: previous, appName: { _ in appName })
    }

    @Test func aDeviceNobodyOwnsIsNotHeld() {
        #expect(!ExclusiveAccess.isHeldByAnother(owner: -1, me: me))
        #expect(hold(output: dac) == nil)
    }

    /// CoreEQ's aggregate could report CoreEQ as the owner. Telling someone that
    /// CoreEQ has locked CoreEQ out would be nonsense.
    @Test func coreEQItselfDoesNotCount() {
        #expect(!ExclusiveAccess.isHeldByAnother(owner: me, me: me))
        #expect(hold(dacOwner: me, output: dac) == nil)
    }

    @Test func anotherProcessTakingTheOutputIsAHoldOnIt() {
        let result = hold(dacOwner: player, output: dac)
        #expect(result?.deviceID == dac)
        #expect(result?.wasOutput == true)
    }

    /// The measured sequence. The hold is seen while the path is still on the DAC,
    /// then the path rebuilds on the speakers, and the answer must not change.
    @Test func theHoldSurvivesThePathMovingToTheFallback() {
        let first = hold(dacOwner: player, output: dac)
        let afterMoving = hold(dacOwner: player, output: speakers, previous: first)
        #expect(afterMoving?.deviceID == dac)
        #expect(afterMoving?.wasOutput == true)
    }

    /// A DJ application keeping a controller to itself while the speakers are
    /// equalized. Worth a mention, not worth saying the equalizer has stopped.
    @Test func aHoldOnAnotherDeviceWasNeverTheOutput() {
        let result = hold(dacOwner: player, output: speakers)
        #expect(result?.deviceID == dac)
        #expect(result?.wasOutput == false)
    }

    @Test func theDeviceCoreEQWasOnWinsOverAnyOther() {
        let result = hold(dacOwner: player, speakersOwner: 300, output: dac)
        #expect(result?.deviceID == dac)
    }

    @Test func releasingEndsTheHold() {
        let first = hold(dacOwner: player, output: dac)
        #expect(hold(output: speakers, previous: first) == nil)
    }

    /// A released device taken again by someone later, on a path that has since
    /// moved, was not the output when it was taken.
    @Test func aPreviousHoldOnlyCarriesOverForTheSameDevice() {
        let onSpeakers = hold(speakersOwner: player, output: speakers)
        let result = hold(dacOwner: player, output: speakers, previous: onSpeakers)
        #expect(result?.wasOutput == false)
    }

    @Test func anOwnerThatIsNotAnAppIsStillNamedAsSomething() {
        let result = hold(dacOwner: player, output: dac, appName: nil)
        #expect(result?.appName == nil)
        #expect(result?.summary.isEmpty == false)
        #expect(result?.message.contains("DAC") == true)
    }

    @Test func theMessageNamesTheAppAndTheDevice() {
        let message = hold(dacOwner: player, output: dac)?.message ?? ""
        #expect(message.contains("Player"))
        #expect(message.contains("DAC"))
    }
}
