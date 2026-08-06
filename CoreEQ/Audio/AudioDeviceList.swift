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

    /// Output volume of the default device as 0...1, and whether it can be set
    /// at all. Many digital outputs report no settable volume; the slider is
    /// disabled rather than hidden so the row doesn't change shape when the user
    /// switches devices.
    @Published private(set) var volume: Float = 0
    @Published private(set) var canSetVolume = false
    @Published private(set) var isMuted = false

    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    /// Volume listener on the current default device, replaced whenever the
    /// default changes.
    private var volumeListener: (AudioDeviceID, AudioObjectPropertyListenerBlock)?

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
        if let (deviceID, block) = volumeListener {
            var address = AudioDevices.outputVolumeAddress()
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        }
    }

    // MARK: - Volume

    /// Sets the system output volume. Reads back rather than trusting the write,
    /// so a device that clamps or ignores the value doesn't leave the slider
    /// showing a level the hardware isn't at.
    func setVolume(_ newValue: Float) {
        guard let deviceID = defaultDeviceID, canSetVolume else { return }
        AudioDevices.setVolume(newValue, of: deviceID)
        if AudioDevices.isMuted(of: deviceID), newValue > 0 {
            AudioDevices.setMuted(false, of: deviceID)
        }
        refreshVolume()
    }

    func toggleMuted() {
        guard let deviceID = defaultDeviceID else { return }
        AudioDevices.setMuted(!isMuted, of: deviceID)
        refreshVolume()
    }

    private func refreshVolume() {
        guard let deviceID = defaultDeviceID else {
            volume = 0
            canSetVolume = false
            isMuted = false
            return
        }
        volume = AudioDevices.volume(of: deviceID) ?? 0
        canSetVolume = AudioDevices.canSetVolume(of: deviceID)
        isMuted = AudioDevices.isMuted(of: deviceID)
    }

    /// Follows the volume of whichever device is currently the default, so the
    /// slider tracks changes made from the system menu or a keyboard key.
    private func observeVolume(of deviceID: AudioDeviceID?) {
        if let (previous, block) = volumeListener {
            var address = AudioDevices.outputVolumeAddress()
            AudioObjectRemovePropertyListenerBlock(previous, &address, .main, block)
            volumeListener = nil
        }
        guard let deviceID else { return }

        var address = AudioDevices.outputVolumeAddress()
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in self?.refreshVolume() }
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
            volumeListener = (deviceID, block)
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
        let newDefault = AudioDevices.defaultOutputDeviceID()
        if newDefault != defaultDeviceID || volumeListener?.0 != newDefault {
            defaultDeviceID = newDefault
            observeVolume(of: newDefault)
        }
        refreshVolume()
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
