import Foundation
import Testing

/// Whether a screen recording is capturing system audio. Every case here was
/// seen on a real Mac: ScreenCaptureKit's `replayd` capturing for a recording,
/// Audacity and QuickTime recording the microphone, and `corespeechd`
/// listening for Siri — the false pause 1.9 shipped with.
struct RecordingDetectionTests {
    private func process(_ bundleID: String, capturing: Bool = true) -> RecordingDetection.Process {
        RecordingDetection.Process(bundleID: bundleID, isRunningInput: capturing)
    }

    @Test func aScreenCaptureIsARecording() {
        #expect(RecordingDetection.isRecordingSystemAudio([process("com.apple.replayd")]))
    }

    /// The 1.9 false positive: Siri listening is capturing with no input
    /// device, as a tap is, and is not a recording.
    @Test func siriListeningIsNotARecording() {
        #expect(!RecordingDetection.isRecordingSystemAudio([process("com.apple.corespeechd")]))
    }

    /// A microphone recording hears CoreEQ once, through the air. Pausing for
    /// it would stop the EQ for every voice memo and call.
    @Test func aMicrophoneRecordingIsLeftAlone() {
        let recorders = [
            process("org.audacityteam.audacity4"), process("com.apple.QuickTimePlayerX"),
        ]
        #expect(!RecordingDetection.isRecordingSystemAudio(recorders))
    }

    /// CoreEQ's own capture is a tap too, and it is not a recording.
    @Test func coreEQsOwnCaptureIsNotARecording() {
        #expect(!RecordingDetection.isRecordingSystemAudio([process("com.andreypudov.coreeq")]))
    }

    /// `replayd` runs all the time; only its capturing means a recording. A
    /// video-only capture was measured to leave it idle.
    @Test func screenCaptureThatIsNotCapturingIsIgnored() {
        #expect(
            !RecordingDetection.isRecordingSystemAudio([
                process("com.apple.replayd", capturing: false)
            ]))
    }

    @Test func oneScreenCaptureAmongOtherCapturesIsEnough() {
        let processes = [
            process("com.apple.corespeechd"), process("com.apple.QuickTimePlayerX"),
            process("com.apple.replayd"),
        ]
        #expect(RecordingDetection.isRecordingSystemAudio(processes))
    }
}
