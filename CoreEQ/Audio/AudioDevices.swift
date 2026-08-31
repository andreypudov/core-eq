import AudioToolbox
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
        /// SF Symbol matching the device's transport type, mirroring the icons
        /// the system Sound menu shows next to each output.
        let symbolName: String
    }

    private static let logger = Logger(
        subsystem: "com.andreypudov.coreeq", category: "AudioDevices")

    /// UID prefix of the private aggregate device `AudioEngine` creates to render
    /// the equalized signal. Devices with this prefix are CoreEQ's own plumbing
    /// and must never be offered as a selectable output.
    static let coreEQAggregateUIDPrefix = "com.andreypudov.coreeq.aggregate."

    /// All devices that can play audio (have at least one output channel),
    /// excluding CoreEQ's own aggregate device, sorted by name.
    static func outputDevices() -> [Device] {
        allDeviceIDs()
            .filter { hasOutputChannels($0) && !isCoreEQAggregate($0) }
            .compactMap { id in
                name(of: id).map { Device(id: id, name: $0, symbolName: symbolName(for: id)) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every output device, as the diagnostics report shows it.
    static func deviceReports() -> [DiagnosticsReport.Device] {
        let defaultID = defaultOutputDeviceID()
        return allDeviceIDs()
            .filter { hasOutputChannels($0) && !isCoreEQAggregate($0) }
            .compactMap { id in
                guard let name = name(of: id) else { return nil }
                return DiagnosticsReport.Device(
                    name: name,
                    uid: persistentID(of: id) ?? "unknown",
                    transport: transportDescription(of: id),
                    isAggregate: isAggregate(id),
                    isDefaultOutput: id == defaultID,
                    bufferChannels: outputBufferChannels(of: id),
                    streamChannels: outputStreamChannelCounts(of: id),
                    preferredStereo: preferredStereoPair(of: id),
                    lfeChannels: lfeChannels(of: id)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Channels in each output buffer, in the shape the render path receives.
    static func outputBufferChannels(of deviceID: AudioDeviceID) -> [Int] {
        bufferChannels(of: deviceID, scope: kAudioObjectPropertyScopeOutput)
    }

    /// Channels in each *input* buffer the device presents.
    ///
    /// Not for capture — CoreEQ never records anything. This is how the tap is
    /// found. The aggregate lists its sub-device's input buffers first and the
    /// tap's after them, so a duplex output device pushes the tap down the input
    /// list by exactly this many buffers.
    static func inputBufferChannels(of deviceID: AudioDeviceID) -> [Int] {
        bufferChannels(of: deviceID, scope: kAudioObjectPropertyScopeInput)
    }

    private static func bufferChannels(
        of deviceID: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> [Int] {
        var configAddress = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(deviceID, &configAddress, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else { return [] }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard
            AudioObjectGetPropertyData(deviceID, &configAddress, 0, nil, &dataSize, bufferList)
                == noErr
        else { return [] }

        let buffers = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return (0..<buffers.count).map { Int(buffers[$0].mNumberChannels) }
    }

    /// Human-readable transport, for the diagnostics report.
    static func transportDescription(of deviceID: AudioDeviceID) -> String {
        switch transportType(of: deviceID) {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        default: return "unknown"
        }
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

    /// Whether the device is an Aggregate or Multi-Output Device — one built
    /// out of other devices rather than backed by hardware of its own.
    ///
    /// Both kinds report the aggregate transport type, so this single question
    /// covers both. `AudioEngine` needs it because Core Audio will not nest an
    /// aggregate inside another one.
    static func isAggregate(_ deviceID: AudioDeviceID) -> Bool {
        transportType(of: deviceID) == kAudioDeviceTransportTypeAggregate
    }

    /// Whether the device presents anywhere to write audio. False for a device
    /// whose output stream configuration is empty, which is not the same thing
    /// as a device that failed to be created.
    static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else {
            return false
        }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr
        else {
            return false
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    /// Channel count of each output stream, in the device's own order.
    ///
    /// A device-bound tap binds to one stream, so a device with several needs a
    /// choice made — `OutputPlan.widestStream` makes it.
    static func outputStreamChannelCounts(of deviceID: AudioDeviceID) -> [Int] {
        var streamAddress = address(
            kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else { return [] }

        var streams = [AudioObjectID](
            repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &dataSize, &streams)
                == noErr
        else { return [] }

        return streams.map { stream in
            var formatAddress = address(kAudioStreamPropertyVirtualFormat)
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard
                AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format)
                    == noErr
            else { return 0 }
            return Int(format.mChannelsPerFrame)
        }
    }

    /// The device's own idea of which two channels carry stereo, zero-based.
    ///
    /// The Core Audio header is explicit that "there are no restrictions on the
    /// channel numbers that can be used", and reports them 1-based. Devices are
    /// free not to answer, and an HDMI display tested here does not.
    static func preferredStereoPair(of deviceID: AudioDeviceID) -> StereoPair? {
        var stereoAddress = address(
            kAudioDevicePropertyPreferredChannelsForStereo,
            scope: kAudioObjectPropertyScopeOutput)
        var pair: (UInt32, UInt32) = (0, 0)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        guard AudioObjectGetPropertyData(deviceID, &stereoAddress, 0, nil, &size, &pair) == noErr,
            pair.0 > 0, pair.1 > 0
        else { return nil }
        return StereoPair(left: Int(pair.0) - 1, right: Int(pair.1) - 1)
    }

    /// Total output channels the device presents across all its buffers.
    /// Zero-based channels the device says carry LFE, or an empty array when it
    /// does not describe its layout.
    ///
    /// Read from `kAudioDevicePropertyPreferredChannelLayout`, which a device is
    /// free not to answer — an HDMI display tested here does not. Absence is
    /// reported as "no roles known", never guessed at from the channel count: a
    /// 5.1 layout's LFE is channel 3, a 7.1.4 layout's is also 3, and a device
    /// with six channels and no layout might be neither.
    static func lfeChannels(of deviceID: AudioDeviceID) -> [Int] {
        labels(of: deviceID).enumerated()
            .filter {
                $0.element == kAudioChannelLabel_LFEScreen
                    || $0.element == kAudioChannelLabel_LFE2
            }
            .map(\.offset)
    }

    /// The device's channel labels, in channel order. Empty when it reports no
    /// layout, or reports one in a form that carries no per-channel roles.
    static func labels(of deviceID: AudioDeviceID) -> [AudioChannelLabel] {
        var layoutAddress = address(
            kAudioDevicePropertyPreferredChannelLayout, scope: kAudioObjectPropertyScopeOutput)
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(deviceID, &layoutAddress, 0, nil, &dataSize) == noErr,
            dataSize >= UInt32(MemoryLayout<AudioChannelLayout>.size)
        else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard
            AudioObjectGetPropertyData(deviceID, &layoutAddress, 0, nil, &dataSize, raw) == noErr
        else { return [] }

        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            let count = Int(layout.pointee.mNumberChannelDescriptions)
            guard count > 0 else { return [] }
            let descriptions = withUnsafeMutablePointer(
                to: &layout.pointee.mChannelDescriptions
            ) {
                UnsafeBufferPointer(
                    start: UnsafeMutableRawPointer($0).assumingMemoryBound(
                        to: AudioChannelDescription.self), count: count)
            }
            return descriptions.map(\.mChannelLabel)
        }
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            return ChannelRoles.labels(fromBitmap: layout.pointee.mChannelBitmap)
        }
        return labels(forTag: tag)
    }

    /// Expands a layout tag — "5.1", "7.1.4" — into per-channel labels, which is
    /// the only way to learn which channel a tag calls LFE.
    private static func labels(forTag tag: AudioChannelLayoutTag) -> [AudioChannelLabel] {
        var tag = tag
        var size: UInt32 = 0
        guard
            AudioFormatGetPropertyInfo(
                kAudioFormatProperty_ChannelLayoutForTag,
                UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tag, &size) == noErr,
            size >= UInt32(MemoryLayout<AudioChannelLayout>.size)
        else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard
            AudioFormatGetProperty(
                kAudioFormatProperty_ChannelLayoutForTag,
                UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tag, &size, raw) == noErr
        else { return [] }

        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        guard count > 0 else { return [] }
        return withUnsafeMutablePointer(to: &layout.pointee.mChannelDescriptions) {
            UnsafeBufferPointer(
                start: UnsafeMutableRawPointer($0).assumingMemoryBound(
                    to: AudioChannelDescription.self), count: count)
        }.map(\.mChannelLabel)
    }

    static func outputChannelCount(of deviceID: AudioDeviceID) -> Int {
        outputBufferChannels(of: deviceID).reduce(0, +)
    }

    static func name(of deviceID: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    /// Persistent identifier for a device.
    ///
    /// `AudioDeviceID` is assigned per boot and reused, so it can't key anything
    /// that outlives a session. The UID survives reboots and reconnections,
    /// which is what makes "the EQ I set for these headphones" stick.
    static func persistentID(of deviceID: AudioDeviceID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    // MARK: - Private

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
            ) == noErr
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
            ) == noErr
        else { return [] }
        return ids
    }

    /// SF Symbol for the device, approximating the system Sound menu's
    /// per-device icons. Combines three signals, most specific first: the
    /// device name (AirPods models, headsets), the built-in device's data
    /// source (internal speakers vs the headphone jack), and finally the
    /// transport type.
    private static func symbolName(for deviceID: AudioDeviceID) -> String {
        let name = (name(of: deviceID) ?? "").lowercased()

        // Name cues identify headphone-class devices regardless of transport
        // (USB / Bluetooth headsets, the jack's "External Headphones", …).
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if ["headphone", "headset", "earphone", "buds"].contains(where: name.contains) {
            return "headphones"
        }

        switch transportType(of: deviceID) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return "display"
        case kAudioDeviceTransportTypeBuiltIn:
            return builtInSymbol(for: deviceID, name: name)
        default:
            return "speaker.wave.2"
        }
    }

    /// Distinguishes the laptop's internal speakers from the headphone jack:
    /// both are `builtIn` transport, but their output data source differs
    /// ('ispk' internal speakers vs 'hdpn' headphones).
    private static func builtInSymbol(for deviceID: AudioDeviceID, name: String) -> String {
        let headphonesSource: UInt32 = 0x6864_706E  // 'hdpn'
        var address = address(
            kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source) == noErr,
            source == headphonesSource
        {
            return "headphones"
        }
        // Internal speakers: laptop glyph on MacBooks, generic speaker on
        // desktop Macs.
        return name.contains("macbook") ? "laptopcomputer" : "speaker.wave.2"
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return kAudioDeviceTransportTypeUnknown }
        return value
    }

    private static func isCoreEQAggregate(_ deviceID: AudioDeviceID) -> Bool {
        guard let uid = persistentID(of: deviceID) else { return false }
        return uid.hasPrefix(coreEQAggregateUIDPrefix)
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress
    {
        address(selector)
    }
}
