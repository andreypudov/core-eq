import Combine
import CoreAudio
import Foundation

/// Observable mirror of the system's output devices for the main window's
/// Output popup. Core Audio property listeners keep it current, so plugging in
/// headphones or switching output from elsewhere updates the popup live rather
/// than only when it is reopened.
@MainActor
final class AudioDeviceList: ObservableObject {
    @Published private(set) var devices: [AudioDevices.Device] = []
    @Published private(set) var defaultDeviceID: AudioDeviceID?

    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

    init() {
        refresh()
        observe(kAudioHardwarePropertyDevices)
        observe(kAudioHardwarePropertyDefaultOutputDevice)
    }

    deinit {
        for (selector, block) in listeners {
            var address = AudioDevices.systemAddress(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
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

    /// Persistent UID of the current default output, which is what per-device
    /// settings are keyed by. Nil when there is no usable output device.
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
        defaultDeviceID = AudioDevices.defaultOutputDeviceID()
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
        }
    }
}
