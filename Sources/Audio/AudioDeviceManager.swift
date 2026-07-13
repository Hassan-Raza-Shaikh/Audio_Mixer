import Foundation
import CoreAudio

/// Manages system-level CoreAudio hardware queries and operations
public final class AudioDeviceManager: Sendable {
    public static let shared = AudioDeviceManager()
    
    private init() {}
    
    /// Queries the HAL for available audio OUTPUT devices only.
    /// Properly filters out microphone/input-only devices and deduplicates.
    public func fetchOutputDevices() -> [AudioDevice] {
        var devicesList: [AudioDevice] = []
        var seenNames: Set<String> = []
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        
        guard status == noErr else { return fallbackDevices() }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        )
        
        guard dataStatus == noErr else { return fallbackDevices() }
        
        let defaultID = getDefaultOutputDeviceID()
        
        for deviceID in deviceIDs {
            guard hasOutputChannels(deviceID: deviceID) else { continue }
            guard !isHidden(deviceID: deviceID) else { continue }
            guard !isPureInputDevice(deviceID: deviceID) else { continue }
            
            let name = getDeviceName(deviceID: deviceID)
            let uid = getDeviceUID(deviceID: deviceID)
            let isDefault = deviceID == defaultID
            
            // Deduplicate by name
            if seenNames.contains(name) { continue }
            seenNames.insert(name)
            
            devicesList.append(AudioDevice(id: uid, name: name, isDefault: isDefault))
        }
        
        if devicesList.isEmpty { return fallbackDevices() }
        
        // Sort: default first, then alphabetically
        return devicesList.sorted { a, b in
            if a.isDefault { return true }
            if b.isDefault { return false }
            return a.name < b.name
        }
    }
    
    public func getDeviceID(for uid: String) -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return nil }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return nil }
        
        for id in deviceIDs {
            if getDeviceUID(deviceID: id) == uid {
                return id
            }
        }
        return nil
    }

    public func setDefaultOutputDevice(deviceID: AudioDevice) {
        print("CoreAudio HAL: Setting default output to \(deviceID.name)")
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let id = getDeviceID(for: deviceID.id) {
            var rawID = id
            let sz = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, sz, &rawID)
        }
    }
    
    // MARK: - Private Helpers
    
    private func getDefaultOutputDeviceID() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = AudioObjectID(0)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &devID)
        return devID
    }
    
    private func hasOutputChannels(deviceID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else { return false }
        
        let buffer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, buffer) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(buffer).contains { $0.mNumberChannels > 0 }
    }
    
    private func isPureInputDevice(deviceID: AudioObjectID) -> Bool {
        // Filter Continuity Camera (iPhone mic)
        let transport = getTransportType(deviceID: deviceID)
        if transport == kAudioDeviceTransportTypeContinuityCapture { return true }
        
        // Remove strict blocklists for virtual devices (like Teams, Soundflower, Aux, Bluetooth)
        // Only block devices that explicitly have no outputs or are Continuity cameras.
        return false
    }
    
    private func getTransportType(deviceID: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var val: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, &val)
        return val
    }
    
    private func getDeviceName(deviceID: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cf: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, &cf) == noErr,
              let name = cf?.takeRetainedValue() else { return "Unknown (\(deviceID))" }
        return name as String
    }
    
    private func getDeviceUID(deviceID: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cf: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, &cf) == noErr,
              let uid = cf?.takeRetainedValue() else { return "uid_\(deviceID)" }
        return uid as String
    }
    
    private func isHidden(deviceID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var val: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, &val)
        return status == noErr && val != 0
    }
    
    private func fallbackDevices() -> [AudioDevice] {
        return [
            AudioDevice(id: "built_in_speakers", name: "MacBook Pro Speakers", isDefault: true),
            AudioDevice(id: "headphones_bt", name: "AirPods Pro", isDefault: false)
        ]
    }
}
