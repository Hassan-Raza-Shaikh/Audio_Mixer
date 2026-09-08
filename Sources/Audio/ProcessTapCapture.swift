import Foundation
import CoreAudio
import AVFoundation

/// Captures a single process's audio using the Core Audio process-tap API
/// (macOS 14.4+). Unlike ScreenCaptureKit, a process tap can *mute the app's
/// original output* while we replay the captured samples to the user's chosen
/// device — so audio isn't heard twice. Delivered buffers are float32,
/// non-interleaved, matching what `PlaybackChannel` expects.
///
/// Setup can fail (unsupported OS, transient CoreAudio errors); callers should
/// fall back to another capture path when `start()` returns false.
final class ProcessTapCapture: @unchecked Sendable {
    private let pid: Int32
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var tapFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(pid: Int32, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.pid = pid
        self.onBuffer = onBuffer
    }

    // MARK: - Lifecycle

    func start() -> Bool {
        guard let processObject = Self.processObject(for: pid) else {
            print("ProcessTap: could not translate PID \(pid) to a process object")
            return false
        }

        // Describe a stereo mixdown tap of just this process, muting the app's
        // own hardware output so we don't get doubled audio.
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "Aura-Tap-\(pid)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else {
            print("ProcessTap: AudioHardwareCreateProcessTap failed (\(err))")
            return false
        }

        // Wrap the tap in a private aggregate device we can run an IO proc on.
        let aggUID = "Aura.Aggregate.\(pid).\(UUID().uuidString)"
        let tapUID = description.uuid.uuidString
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceNameKey as String: "Aura Aggregate \(pid)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggregateID)
        guard err == noErr, aggregateID != kAudioObjectUnknown else {
            print("ProcessTap: AudioHardwareCreateAggregateDevice failed (\(err))")
            teardown()
            return false
        }

        // Resolve the tap's stream format on the aggregate's input scope.
        guard let format = tapStreamFormat() else {
            print("ProcessTap: could not read tap stream format")
            teardown()
            return false
        }
        tapFormat = format

        // We hand the playback path a standard non-interleaved float32 buffer.
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: max(1, format.channelCount),
            interleaved: false
        ) else {
            teardown()
            return false
        }
        outputFormat = outFormat
        if format != outFormat {
            converter = AVAudioConverter(from: format, to: outFormat)
        }

        // Install an IO proc; the tapped audio arrives as the device's input.
        let queue = DispatchQueue(label: "com.hassan.Aura.Tap.\(pid)")
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleInput(inInputData)
        }
        guard err == noErr, ioProcID != nil else {
            print("ProcessTap: AudioDeviceCreateIOProcIDWithBlock failed (\(err))")
            teardown()
            return false
        }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else {
            print("ProcessTap: AudioDeviceStart failed (\(err))")
            teardown()
            return false
        }

        print("ProcessTap: capturing PID \(pid) (\(Int(format.sampleRate))Hz, \(format.channelCount)ch)")
        return true
    }

    func stop() {
        teardown()
    }

    private func teardown() {
        if let ioProcID {
            if aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - IO

    private func handleInput(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let outputFormat else { return }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let firstBuffer = inList.first, firstBuffer.mData != nil else { return }

        let bytesPerFrame = max(1, Int(tapFormat.streamDescription.pointee.mBytesPerFrame))
        let frameCount = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0 else { return }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frameCount) else { return }
        sourceBuffer.frameLength = frameCount

        // Copy the transient callback memory into our buffer.
        let destList = UnsafeMutableAudioBufferListPointer(sourceBuffer.mutableAudioBufferList)
        for i in 0..<min(destList.count, inList.count) {
            guard let src = inList[i].mData, let dst = destList[i].mData else { continue }
            let bytes = Int(min(inList[i].mDataByteSize, destList[i].mDataByteSize))
            memcpy(dst, src, bytes)
        }

        // Convert to the standard non-interleaved float32 the playback expects.
        guard let converter else { onBuffer(sourceBuffer); return }

        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: converted, error: &convError) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if status == .haveData || status == .inputRanDry {
            onBuffer(converted)
        }
    }

    // MARK: - CoreAudio helpers

    private func tapStreamFormat() -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &asbd)
        guard err == noErr, asbd.mSampleRate > 0 else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    private static func processObject(for pid: Int32) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputPID = pid
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &inputPID,
            &size,
            &processObject
        )
        guard err == noErr, processObject != kAudioObjectUnknown else { return nil }
        return processObject
    }
}
