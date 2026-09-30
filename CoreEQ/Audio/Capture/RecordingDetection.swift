import Foundation

/// Whether another process is recording system audio — the case in which
/// CoreEQ makes the recording sound doubled.
///
/// A recorder captures each application's sound before CoreEQ's tap mutes it at
/// the device, and it also captures CoreEQ's own output: the same audio,
/// equalized, 27 ms later. Measured through ScreenCaptureKit, the copy is a
/// third as loud on a headphone preset and nearly as loud at Flat, and the two
/// together are heard as an echo. Switching CoreEQ off removes it.
///
/// The rule: a process capturing input whose input devices include no real
/// device is reading a tap, and a tap is system audio. Measured, a
/// ScreenCaptureKit capture shows as `replayd` running input with no input
/// device, from the moment it starts to the moment it stops. Audacity and
/// QuickTime recording the microphone show as running input *from the
/// microphone*, and are correctly left alone — a microphone recording hears
/// CoreEQ's output only once, through the air.
///
/// Not seen: a recorder that loops audio through a virtual device, such as
/// BlackHole, which reads from a device like any microphone.
///
/// Pure, and its own type, because the engine cannot be reached by a test.
enum RecordingDetection {
    /// One audio process as Core Audio reports it.
    struct Process: Equatable {
        let pid: Int32
        let isRunningInput: Bool
        /// Devices the process is capturing from. Zero while capturing means a
        /// tap.
        let inputDeviceCount: Int
    }

    static func isRecordingSystemAudio(_ processes: [Process], excluding ownPID: Int32) -> Bool {
        processes.contains { process in
            // CoreEQ's own capture is a tap too, and it is not a recording.
            process.pid != ownPID && process.isRunningInput && process.inputDeviceCount == 0
        }
    }
}
