import CoreAudio
import Foundation

/// Another process holding an output device in hog mode, which CoreEQ can only
/// report.
///
/// Measured with `make hog-test`, and none of it was what the property suggests:
/// macOS moves the default output off a hogged device as soon as hog mode is
/// taken, when it has another device to move to. So by the time CoreEQ has
/// rebuilt, the device being held is no longer the one it is on, and asking only
/// the current output says that nobody holds anything. Every output device has to
/// be asked. A tap hears nothing from the process holding the device, and the
/// aggregate around that device delivers no IO until it is released.
enum ExclusiveAccess {

    /// One output device, and who owns it. `owner` is -1 when it is shared.
    struct Reading: Equatable {
        let deviceID: AudioObjectID
        let deviceName: String
        let owner: pid_t
    }

    struct Hold: Equatable {
        let deviceID: AudioObjectID
        let deviceName: String
        /// Nil when the owner is not an app, such as a command-line player.
        let appName: String?
        /// Whether this is the device CoreEQ was on when it was taken, so that
        /// the sound the user is listening to is what CoreEQ can no longer reach.
        /// False is a player holding some other device: a controller a DJ
        /// application keeps to itself, while the Mac's speakers are equalized.
        let wasOutput: Bool

        var summary: String {
            if let appName {
                return String(
                    localized: "\(appName) Has Exclusive Access",
                    comment: "Menu row: the app holding an output device to itself")
            }
            return String(
                localized: "Another App Has Exclusive Access",
                comment: "Menu row: an unnamed app holding an output device to itself")
        }

        var message: String {
            if let appName {
                return String(
                    localized:
                        "\(appName) has exclusive access to “\(deviceName)”, so its sound isn’t being equalized. The equalizer returns when \(appName) lets go.",
                    comment: "Engine status: an app holds an output device to itself")
            }
            return String(
                localized:
                    "Another app has exclusive access to “\(deviceName)”, so its sound isn’t being equalized. The equalizer returns when that app lets go.",
                comment: "Engine status: an unnamed app holds an output device to itself")
        }
    }

    /// Whether `owner` is another process. CoreEQ's own pid counts as nobody, and
    /// so does anything else that is not a process.
    static func isHeldByAnother(owner: pid_t, me: pid_t) -> Bool {
        owner > 0 && owner != me
    }

    /// The hold worth reporting, out of everything being held right now.
    ///
    /// - Parameters:
    ///   - readings: every output device.
    ///   - me: CoreEQ's own pid.
    ///   - output: the device the audio path is built around, if any.
    ///   - previous: the last answer. `wasOutput` is only knowable in the moment
    ///     a device is taken, since the path then moves to another device, so it
    ///     carries over for as long as that device stays held.
    ///   - appName: names the process that owns a device.
    /// - Returns: the hold on CoreEQ's own output if there is one, or nil when
    ///   nothing is held.
    static func currentHold(
        in readings: [Reading], me: pid_t, output: AudioObjectID?, previous: Hold?,
        appName: (pid_t) -> String?
    ) -> Hold? {
        let holds = readings.filter { isHeldByAnother(owner: $0.owner, me: me) }
        func wasOutput(_ reading: Reading) -> Bool {
            reading.deviceID == output
                || (reading.deviceID == previous?.deviceID && previous?.wasOutput == true)
        }
        guard let chosen = holds.first(where: wasOutput) ?? holds.first else { return nil }
        return Hold(
            deviceID: chosen.deviceID, deviceName: chosen.deviceName,
            appName: appName(chosen.owner), wasOutput: wasOutput(chosen))
    }
}
