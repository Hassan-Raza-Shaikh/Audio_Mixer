import CoreAudio
import Foundation

/// An audio output device, identified by its stable Core Audio UID.
struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: String          // kAudioDevicePropertyDeviceUID
    let name: String
    let isDefault: Bool

    var shortName: String {
        let parts = name.split(separator: " ")
        return parts.count > 2 ? parts.prefix(2).joined(separator: " ") : name
    }
}

/// Output-device queries, change notifications, and system default routing.
final class AudioDeviceManager: Sendable {
    static let shared = AudioDeviceManager()
    private init() {}

    /// Output-capable devices, default first then alphabetical. Excludes
    /// hidden devices, Continuity Camera, and Aura's own routing devices.
    func outputDevices() -> [AudioDevice] {
        let defaultID = defaultOutputDeviceID()
        var seen = Set<String>()
        var devices: [AudioDevice] = []

        for id in AudioHAL.objectList(AudioHAL.systemObject, kAudioHardwarePropertyDevices) {
            guard hasOutputChannels(id), !isHidden(id), !isContinuityCapture(id),
                  let uid = AudioHAL.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(AppAudioRoute.aggregateUIDPrefix),
                  seen.insert(uid).inserted else { continue }
            let name = AudioHAL.string(id, kAudioObjectPropertyName) ?? "Output \(id)"
            devices.append(AudioDevice(id: uid, name: name, isDefault: id == defaultID))
        }

        return devices.sorted {
            ($0.isDefault ? 0 : 1, $0.name.localizedLowercase) < ($1.isDefault ? 0 : 1, $1.name.localizedLowercase)
        }
    }

    func defaultOutputDeviceID() -> AudioObjectID {
        AudioHAL.value(AudioHAL.systemObject, kAudioHardwarePropertyDefaultOutputDevice,
                       fallback: AudioObjectID(kAudioObjectUnknown))
    }

    func defaultOutputDeviceUID() -> String? {
        let id = defaultOutputDeviceID()
        guard id != kAudioObjectUnknown else { return nil }
        return AudioHAL.string(id, kAudioDevicePropertyDeviceUID)
    }

    func deviceID(forUID uid: String) -> AudioObjectID? {
        AudioHAL.objectList(AudioHAL.systemObject, kAudioHardwarePropertyDevices)
            .first { AudioHAL.string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Makes `uid` the system-wide default output device.
    @discardableResult
    func setDefaultOutputDevice(uid: String) -> Bool {
        guard var id = deviceID(forUID: uid) else { return false }
        var addr = AudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectSetPropertyData(AudioHAL.systemObject, &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &id) == noErr
    }

    /// Invokes `handler` (on the main queue) when devices are added/removed or
    /// the system default output changes.
    func observeChanges(_ handler: @escaping @Sendable () -> Void) {
        AudioHAL.observe(AudioHAL.systemObject, kAudioHardwarePropertyDevices, handler: handler)
        AudioHAL.observe(AudioHAL.systemObject, kAudioHardwarePropertyDefaultOutputDevice, handler: handler)
    }

    // MARK: - Private

    private func hasOutputChannels(_ id: AudioObjectID) -> Bool {
        var addr = AudioHAL.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private func isHidden(_ id: AudioObjectID) -> Bool {
        AudioHAL.value(id, kAudioDevicePropertyIsHidden, fallback: UInt32(0)) != 0
    }

    private func isContinuityCapture(_ id: AudioObjectID) -> Bool {
        let transport = AudioHAL.value(id, kAudioDevicePropertyTransportType, fallback: UInt32(0))
        return transport == kAudioDeviceTransportTypeContinuityCaptureWired
            || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
    }
}
