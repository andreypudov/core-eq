import AppKit
import CoreAudio
import Foundation
import os

/// Watches every output device for another process taking hog mode.
///
/// A listener rather than a poll: hog mode measured as notifying on both take and
/// release, and from another process. What it means is decided, and tested, in
/// `ExclusiveAccess`.
@MainActor
final class ExclusiveAccessMonitor {
    private let logger = Logger(subsystem: "com.andreypudov.coreeq", category: "ExclusiveAccess")
    private let onChange: () -> Void
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    /// - Parameter onChange: called on the main actor when any device's owner may
    ///   have changed. Ask `readings()` for what it is now.
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    var isStarted: Bool { deviceListListener != nil }

    func start() {
        guard !isStarted else { return }
        var address = AudioDevices.systemAddress(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.followDevices()
                self.onChange()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr {
            deviceListListener = block
        } else {
            logger.error("Failed to observe the device list: \(status)")
        }
        followDevices()
    }

    func stop() {
        if let deviceListListener {
            var address = AudioDevices.systemAddress(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListListener)
        }
        deviceListListener = nil
        for deviceID in Array(deviceListeners.keys) { stopListening(to: deviceID) }
    }

    func readings() -> [ExclusiveAccess.Reading] {
        AudioDevices.outputDevices().map { device in
            ExclusiveAccess.Reading(
                deviceID: device.id, deviceName: device.name,
                owner: AudioDevices.hogModeOwner(of: device.id))
        }
    }

    nonisolated static func appName(of pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    private func followDevices() {
        let current = Set(AudioDevices.outputDevices().map(\.id))
        for deviceID in deviceListeners.keys where !current.contains(deviceID) {
            stopListening(to: deviceID)
        }
        for deviceID in current where deviceListeners[deviceID] == nil {
            var address = AudioDevices.hogModeAddress
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange() }
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
            if status == noErr {
                deviceListeners[deviceID] = block
            } else {
                logger.error("Failed to observe hog mode on \(deviceID): \(status)")
            }
        }
    }

    private func stopListening(to deviceID: AudioObjectID) {
        guard let block = deviceListeners.removeValue(forKey: deviceID) else { return }
        var address = AudioDevices.hogModeAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
    }
}
