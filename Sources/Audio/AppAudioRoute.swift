@preconcurrency import AVFoundation
import CoreAudio
import os

/// Routes one app's audio through Aura.
///
/// A Core Audio process tap captures every audio process belonging to the app
/// (including helpers — browsers and Electron apps play sound from helper
/// processes) and mutes their normal output. The tap and the chosen output
/// device are combined into one private aggregate device, so each IO cycle
/// hands us the tapped samples *and* the output buffer together: we apply
/// volume / balance / mute and write straight to the device. No intermediate
/// queue, no added latency, and drift between clocks is compensated by the HAL.
final class AppAudioRoute: @unchecked Sendable {
    struct Mix: Sendable, Equatable {
        var volume: Float = 1       // 0…1
        var pan: Float = 0          // -1 (left) … +1 (right)
        var muted = false
    }

    enum RouteError: Error, CustomStringConvertible {
        case noAudioProcesses
        case tapFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case unsupportedFormat
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)

        var description: String {
            switch self {
            case .noAudioProcesses: "the app has no audio processes yet"
            case .tapFailed(let s): "AudioHardwareCreateProcessTap failed (\(s))"
            case .aggregateFailed(let s): "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .unsupportedFormat: "the device doesn't use 32-bit float IO"
            case .ioProcFailed(let s): "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
            case .startFailed(let s): "AudioDeviceStart failed (\(s))"
            }
        }
    }

    /// Prefix of the UIDs of Aura's private aggregate devices, so they can be
    /// filtered out of the user-facing device list.
    static let aggregateUIDPrefix = "com.hassan.Aura.route."

    let appName: String
    let processObjects: [AudioObjectID]
    let outputUID: String
    private(set) var sampleRate: Double = 48_000

    private let mix: OSAllocatedUnfairLock<Mix>
    private let levels = OSAllocatedUnfairLock(initialState: Levels())
    /// Non-nil while recording; the IO thread hands it copies of the tapped audio.
    private let recorder = OSAllocatedUnfairLock<AudioFileRecorder?>(uncheckedState: nil)

    /// Gains applied at the end of the previous IO cycle (IO thread only).
    /// Ramping from these avoids zipper noise when the user drags a slider.
    private var appliedGain: (left: Float, right: Float)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    struct Levels: Sendable {
        /// Peak of the tapped audio before Aura's gain (is the app making sound?).
        var source: Float = 0
        /// Peak of what's actually sent to the device (what you hear).
        var output: Float = 0
    }

    init(appName: String, processObjects: [AudioObjectID], outputUID: String, mix: Mix) {
        self.appName = appName
        self.processObjects = processObjects
        self.outputUID = outputUID
        self.mix = OSAllocatedUnfairLock(initialState: mix)
        self.appliedGain = Self.gains(for: mix)
    }

    deinit { teardown() }

    // MARK: - Lifecycle

    func start() throws {
        guard !processObjects.isEmpty else { throw RouteError.noAudioProcesses }

        let tap = CATapDescription(stereoMixdownOfProcesses: processObjects)
        tap.name = "Aura – \(appName)"
        tap.isPrivate = true
        // Silence the app's own output only while we're reading the tap, so if
        // Aura stops (or crashes) the app's audio falls back to normal.
        tap.muteBehavior = .mutedWhenTapped

        var status = AudioHardwareCreateProcessTap(tap, &tapID)
        guard status == noErr else { throw RouteError.tapFailed(status) }

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceNameKey: "Aura – \(appName)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else { teardown(); throw RouteError.aggregateFailed(status) }

        guard Self.usesFloat32(aggregateID, scope: kAudioObjectPropertyScopeInput),
              Self.usesFloat32(aggregateID, scope: kAudioObjectPropertyScopeOutput) else {
            teardown(); throw RouteError.unsupportedFormat
        }
        sampleRate = AudioHAL.value(aggregateID, kAudioDevicePropertyNominalSampleRate, fallback: Float64(48_000))

        // nil queue: run directly on the HAL's real-time IO thread.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, input, _, output, _ in
            self?.render(input: input, output: output)
        }
        guard status == noErr, ioProcID != nil else { teardown(); throw RouteError.ioProcFailed(status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { teardown(); throw RouteError.startFailed(status) }
    }

    func stop() {
        attach(recorder: nil)
        teardown()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        levels.withLock { $0 = Levels() }
    }

    // MARK: - Controls

    func setMix(_ newMix: Mix) {
        mix.withLock { $0 = newMix }
    }

    var currentLevels: Levels {
        levels.withLock { $0 }
    }

    // MARK: - Recording

    /// Starts (or stops, with nil) handing the app's audio — before Aura's
    /// volume/mute — to a recorder. Ignored if the recorder's sample rate
    /// doesn't match this route's device.
    func attach(recorder newRecorder: AudioFileRecorder?) {
        recorder.withLockUnchecked { $0 = newRecorder }
    }

    // MARK: - IO (real-time thread)

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        guard let inL = Self.channel(0, in: inList), let outL = Self.channel(0, in: outList) else { return }
        let inR = Self.channel(1, in: inList) ?? inL
        let outR = Self.channel(1, in: outList)
        let frames = min(inL.frames, inR.frames, outL.frames, outR?.frames ?? .max)
        guard frames > 0 else { return }

        let target = Self.gains(for: mix.withLock { $0 })
        let start = appliedGain
        let stepL = (target.left - start.left) / Float(frames)
        let stepR = (target.right - start.right) / Float(frames)

        var sourcePeak: Float = 0
        var outputPeak: Float = 0
        for i in 0..<frames {
            let l = inL.base[i * inL.stride]
            let r = inR.base[i * inR.stride]
            sourcePeak = max(sourcePeak, abs(l), abs(r))

            let outLeft = l * (start.left + stepL * Float(i + 1))
            let outRight = r * (start.right + stepR * Float(i + 1))
            if let outR {
                outL.base[i * outL.stride] = outLeft
                outR.base[i * outR.stride] = outRight
            } else {
                outL.base[i * outL.stride] = 0.5 * (outLeft + outRight)   // mono device
            }
            outputPeak = max(outputPeak, abs(outLeft), abs(outRight))
        }
        appliedGain = target
        let measured = Levels(source: sourcePeak, output: outputPeak)
        levels.withLock { $0 = measured }

        if let recorder = recorder.withLockUnchecked({ $0 }), recorder.format.sampleRate == sampleRate {
            enqueueRecording(left: inL, right: inR, frames: frames, into: recorder)
        }
    }

    private func enqueueRecording(left: ChannelView, right: ChannelView, frames: Int, into recorder: AudioFileRecorder) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: recorder.format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            dst[0][i] = left.base[i * left.stride]
            dst[1][i] = right.base[i * right.stride]
        }
        recorder.append(buffer)
    }

    // MARK: - Helpers

    /// Interleaving-agnostic view of one channel inside an AudioBufferList.
    private struct ChannelView {
        let base: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    @inline(__always)
    private static func channel(_ index: Int, in list: UnsafeMutableAudioBufferListPointer) -> ChannelView? {
        var remaining = index
        for buffer in list {
            let count = Int(buffer.mNumberChannels)
            guard count > 0 else { continue }
            if remaining < count {
                guard let data = buffer.mData else { return nil }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count)
                return ChannelView(base: data.assumingMemoryBound(to: Float.self).advanced(by: remaining),
                                   stride: count, frames: frames)
            }
            remaining -= count
        }
        return nil
    }

    private static func gains(for mix: Mix) -> (left: Float, right: Float) {
        let volume = mix.muted ? 0 : max(0, min(1, mix.volume))
        let pan = max(-1, min(1, mix.pan))
        return (pan > 0 ? (1 - pan) * volume : volume,
                pan < 0 ? (1 + pan) * volume : volume)
    }

    /// HAL IO procs almost always use 32-bit float; bail out rather than
    /// misinterpret samples if a device says otherwise.
    private static func usesFloat32(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioHAL.address(kAudioDevicePropertyStreamFormat, scope: scope)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &asbd) == noErr else { return true }
        return asbd.mFormatID == kAudioFormatLinearPCM
            && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mBitsPerChannel == 32
    }
}

// MARK: - File recorder

/// Writes stereo float buffers to a 32-bit float WAV file on a background
/// queue, so disk I/O never runs on the real-time audio thread.
final class AudioFileRecorder: @unchecked Sendable {
    let url: URL
    /// Non-interleaved float32 stereo — the format buffers must be in.
    let format: AVAudioFormat
    private let queue = DispatchQueue(label: "com.hassan.Aura.recorder")
    private var file: AVAudioFile?          // queue only

    init(url: URL, sampleRate: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.url = url
        self.format = format
        // WAV must be interleaved on disk; AVAudioFile converts from the
        // non-interleaved processing format we write in.
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in try? file?.write(from: buffer) }
    }

    /// Flushes pending writes and closes the file.
    func finish() {
        queue.sync { file = nil }
    }
}
