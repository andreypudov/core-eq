import Combine
import CoreAudio
import Foundation
import os

/// Observable mirror of the system's output devices for the main window's
/// Output popup. Core Audio property listeners keep it current, so plugging in
/// headphones or switching output from elsewhere updates the popup live rather
/// than only when it is reopened.
@MainActor
final class AudioDeviceList: ObservableObject {
    @Published private(set) var devices: [AudioDevices.Device] = []
    @Published private(set) var defaultDeviceID: AudioDeviceID?

    /// Persistent UID of the current default output, published rather than
    /// derived.
    ///
    /// A computed property over `defaultDeviceID` looks equivalent and is not.
    /// `@Published` emits in `willSet`, so a subscriber that re-reads the object
    /// instead of using the emitted value sees the *previous* device — and per
    /// device settings keyed on that answer get filed under the device the user
    /// just left. Publishing the UID lets a subscriber use what it was handed.
    @Published private(set) var defaultDeviceUID: String?

    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private let logger = Logger(subsystem: "com.andreypudov.coreeq", category: "AudioDeviceList")

    init() {
        refresh()
        observe(kAudioHardwarePropertyDevices)
        observe(kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Isolated for the same reason the listeners were installed on `.main`:
    /// removing a Core Audio property listener has to name the same queue and
    /// the same block it was added with, and both belong to this actor.
    isolated deinit {
        for (selector, block) in listeners {
            var address = AudioDevices.systemAddress(selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    /// The name of the current default output, or a placeholder when Core Audio
    /// reports no usable output device.
    var defaultDeviceName: String {
        defaultDeviceID.flatMap { id in devices.first { $0.id == id }?.name }
            ?? defaultDeviceID.flatMap(AudioDevices.name(of:))
            ?? "No Output Device"
    }

    /// The icon of the current default output. Falls back to the crossed-out
    /// speaker the system uses when nothing can play.
    var defaultDeviceSymbolName: String {
        defaultDeviceID.flatMap { id in devices.first { $0.id == id }?.symbolName }
            ?? devices.first?.symbolName
            ?? "speaker.slash"
    }

    /// Persistent UID of the current default output, read on demand.
    ///
    /// For callers outside a subscription. Anything reacting to a change must
    /// use `$defaultDeviceUID` and the value it emits — see the note there.
    var defaultDevicePersistentID: String? {
        defaultDeviceID.flatMap(AudioDevices.persistentID(of:))
    }

    /// False when the machine has one output — or none. Nothing is selectable
    /// then, so the UI names the device instead of offering a chooser.
    var hasChoice: Bool { devices.count > 1 }

    func select(_ deviceID: AudioDeviceID) {
        guard deviceID != defaultDeviceID else { return }
        AudioDevices.setDefaultOutputDevice(deviceID)
        // The property listener confirms the change; updating optimistically
        // keeps the popup from flickering back to the old selection first.
        defaultDeviceID = deviceID
    }

    func refresh() {
        devices = AudioDevices.outputDevices()
        let id = AudioDevices.defaultOutputDeviceID()
        defaultDeviceID = id
        defaultDeviceUID = id.flatMap(AudioDevices.persistentID(of:))
    }

    private func observe(_ selector: AudioObjectPropertySelector) {
        var address = AudioDevices.systemAddress(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block
        )
        if status == noErr {
            listeners.append((selector, block))
        } else {
            // Silently ignoring this is how the device list can go stale for a
            // whole session while everything else follows the hardware: the EQ
            // keeps filing under a device the user left.
            logger.error(
                "Failed to observe audio property \(selector, privacy: .public): \(status)")
        }
    }
}
