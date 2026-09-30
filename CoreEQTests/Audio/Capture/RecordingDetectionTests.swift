import Foundation
import Testing

/// Whether another process is recording system audio. The cases are the ones
/// measured: ScreenCaptureKit's `replayd` capturing with no input device, and
/// Audacity and QuickTime capturing the microphone.
struct RecordingDetectionTests {
    private let ownPID: Int32 = 100

    private func process(
        _ pid: Int32, input: Bool = true, devices: Int
    ) -> RecordingDetection.Process {
        RecordingDetection.Process(pid: pid, isRunningInput: input, inputDeviceCount: devices)
    }

    @Test func aCaptureWithNoInputDeviceIsASystemAudioRecording() {
        let replayd = process(716, devices: 0)
        #expect(RecordingDetection.isRecordingSystemAudio([replayd], excluding: ownPID))
    }

    /// A microphone recording hears CoreEQ once, through the air. Pausing for
    /// it would stop the EQ for every voice memo and call.
    @Test func aMicrophoneRecordingIsLeftAlone() {
        let audacity = process(25_631, devices: 1)
        let quickTime = process(24_485, devices: 1)
        #expect(
            !RecordingDetection.isRecordingSystemAudio([audacity, quickTime], excluding: ownPID))
    }

    /// CoreEQ's own capture is a tap as well.
    @Test func coreEQsOwnCaptureIsNotARecording() {
        #expect(
            !RecordingDetection.isRecordingSystemAudio(
                [process(ownPID, devices: 0)], excluding: ownPID))
    }

    @Test func aProcessThatIsNotCapturingIsIgnored() {
        #expect(
            !RecordingDetection.isRecordingSystemAudio(
                [process(716, input: false, devices: 0)], excluding: ownPID))
    }

    @Test func oneRecorderAmongMicrophonesIsEnough() {
        let processes = [process(25_631, devices: 1), process(716, devices: 0)]
        #expect(RecordingDetection.isRecordingSystemAudio(processes, excluding: ownPID))
    }
}
