import Foundation

/// Whether a screen recording is capturing system audio — the case in which
/// CoreEQ makes the recording sound doubled.
///
/// A recorder captures each application's sound before CoreEQ's tap mutes it at
/// the device, and it also captures CoreEQ's own output: the same audio,
/// equalized, 27 ms later. Measured through ScreenCaptureKit, the copy is a
/// third as loud on a headphone preset and nearly as loud at Flat, and the two
/// together are heard as an echo. Switching CoreEQ off removes it.
///
/// The rule: `replayd` is capturing. Screen recorders and screen sharing built
/// on ScreenCaptureKit never capture system audio themselves — they ask macOS,
/// and `replayd` does it for them. Measured, it captures from the moment an
/// audio recording starts to the moment it stops, and not at all for a
/// video-only recording or when nothing records.
///
/// Who is capturing, not how the capture looks. 1.9 used "capturing with no
/// input device", reasoning that a process reading a tap reports none. So does
/// `corespeechd`, which listens to the microphone continuously while "Listen
/// for Siri" is on — on Macs with that enabled, CoreEQ paused whenever anything
/// played, and said it was paused for a recording. A listening service is not
/// a recording, and naming the one process that is cannot be fooled by the
/// next one macOS adds.
///
/// Not seen: recorders that tap system audio directly rather than through
/// ScreenCaptureKit, and recorders that loop audio through a virtual device
/// such as BlackHole. Neither was ever measured.
///
/// Pure, and its own type, because the engine cannot be reached by a test.
enum RecordingDetection {
    /// The ScreenCaptureKit service that captures on every recorder's behalf.
    static let screenCaptureService = "com.apple.replayd"

    /// One audio process as Core Audio reports it.
    struct Process: Equatable {
        let bundleID: String
        let isRunningInput: Bool
    }

    static func isRecordingSystemAudio(_ processes: [Process]) -> Bool {
        processes.contains { $0.isRunningInput && $0.bundleID == screenCaptureService }
    }
}
