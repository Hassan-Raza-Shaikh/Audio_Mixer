import CoreAudio
import Foundation

/// Thin, typed helpers over the Core Audio HAL property API.
enum AudioHAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size (plain-data) property, returning `fallback` on error.
    static func value<T>(_ object: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         fallback: T) -> T {
        var addr = address(selector, scope: scope)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &result) { raw in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw.baseAddress!)
        }
        return status == noErr ? result : fallback
    }

    /// Reads a CFString property.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Reads an array-of-AudioObjectID property (device lists, process lists…).
    static func objectList(_ object: AudioObjectID,
                           _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown),
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Calls `handler` on the main queue whenever `selector` changes on `object`.
    /// Listeners live for the lifetime of the app.
    static func observe(_ object: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        handler: @escaping @Sendable () -> Void) {
        var addr = address(selector)
        AudioObjectAddPropertyListenerBlock(object, &addr, .main) { _, _ in handler() }
    }
}

// MARK: - Audio processes

/// A process the HAL knows about because it has opened an audio connection.
/// Apps often play sound from helper processes (browsers, Electron apps,
/// WebKit), so one app can own several of these.
struct AudioProcess: Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    /// True while the process has audio output running (i.e. is playing).
    let isRunningOutput: Bool
}

extension AudioHAL {
    /// Identity of a process object — fixed for its lifetime, so it's cached
    /// to avoid two IPC round-trips per process on every poll.
    struct ProcessIdentity { let pid: pid_t; let bundleID: String }

    static func audioProcesses(identityCache cache: inout [AudioObjectID: ProcessIdentity]) -> [AudioProcess] {
        let ids = objectList(systemObject, kAudioHardwarePropertyProcessObjectList)
        let processes = ids.map { id in
            let identity = cache[id] ?? {
                let fresh = ProcessIdentity(pid: value(id, kAudioProcessPropertyPID, fallback: pid_t(-1)),
                                            bundleID: string(id, kAudioProcessPropertyBundleID) ?? "")
                cache[id] = fresh
                return fresh
            }()
            return AudioProcess(
                objectID: id,
                pid: identity.pid,
                bundleID: identity.bundleID,
                isRunningOutput: value(id, kAudioProcessPropertyIsRunningOutput, fallback: UInt32(0)) != 0
            )
        }
        if cache.count > ids.count {                // drop processes that have gone away
            let live = Set(ids)
            cache = cache.filter { live.contains($0.key) }
        }
        return processes
    }

    static func audioProcesses() -> [AudioProcess] {
        var scratch: [AudioObjectID: ProcessIdentity] = [:]
        return audioProcesses(identityCache: &scratch)
    }
}
