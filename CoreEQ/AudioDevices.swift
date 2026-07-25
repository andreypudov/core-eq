import CoreAudio
import Foundation
import os

/// Read-only enumeration of the system's output devices plus get/set of the
/// default output device, used by the menu-bar Output row.
///
/// CoreEQ never binds its engine to a device here — it only moves the *system*
/// default output. `AudioEngine` already listens for default-device changes and
/// rebuilds its tap/aggregate onto whatever the system points at, so selecting a
/// device in the popover routes CoreEQ there through the same path a user taking
/// the Sound menu would trigger.
enum AudioDevices {
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
    }

    private static let logger = Logger(subsystem: "com.andreypudov.coreeq", category: "AudioDevices")

    /// UID prefix of the private aggregate device `AudioEngine` creates to render
    /// the equalized signal. Devices with this prefix are CoreEQ's own plumbing
    /// and must never be offered as a selectable output.
    static let coreEQAggregateUIDPrefix = "com.andreypudov.coreeq.aggregate."

    /// All devices that can play audio (have at least one output channel),
    /// excluding CoreEQ's own aggregate device, sorted by name.
    static func outputDevices() -> [Device] {
        allDeviceIDs()
            .filter { hasOutputChannels($0) && !isCoreEQAggregate($0) }
            .compactMap { id in name(of: id).map { Device(id: id, name: $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value
        )
        if status != noErr {
            logger.error("Failed to set default output device: \(status)")
        }
    }

    static func name(of deviceID: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name as String
    }

    // MARK: - Private

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func isCoreEQAggregate(_ deviceID: AudioDeviceID) -> Bool {
        guard let uid = uid(of: deviceID) else { return false }
        return uid.hasPrefix(coreEQAggregateUIDPrefix)
    }

    private static func uid(of deviceID: AudioDeviceID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { return nil }
        return uid as String
    }

    private static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }

        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
