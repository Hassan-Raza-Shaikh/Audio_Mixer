@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import os

/// Captures what's being played on the Mac (the system mix) for screen
/// recordings.
///
/// Why not ScreenCaptureKit's audio? A process tap with `.mutedWhenTapped`
/// silences an app at the *hardware*, but every tap — including the one
/// ScreenCaptureKit uses internally — still sees that app's audio *before*
/// the mute. So while Aura is routing an app, a system-wide capture contains
/// both the app's original and Aura's adjusted copy (which partially cancel).
///
/// This capture is a global tap that **excludes the apps Aura is routing** and
/// **includes Aura's own output**, which carries those apps at the user's
/// volume/balance. The result is exactly what you hear.
///
/// The exclusion list is fixed at creation: changing a live tap's process list
/// (kAudioTapPropertyDescription) was measured to take effect unreliably, so
/// callers rebuild the capture when routes change.
final class SystemAudioCapture: @unchecked Sendable {
    typealias Handler = @Sendable (CMSampleBuffer) -> Void

    enum CaptureError: Error { case tap(OSStatus), aggregate(OSStatus), format, ioProc(OSStatus), start(OSStatus) }

    private(set) var sampleRate: Double = 48_000
    private let handler: Handler
    /// Processes left out of the capture (the apps Aura is routing).
    let excludedProcesses: [AudioObjectID]
    private let tapDescription: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var formatDescription: CMAudioFormatDescription?
    private var bytesPerFrame: UInt32 = 8
    private let peak = OSAllocatedUnfairLock(initialState: Float(0))
    private let log = Logger(subsystem: "com.hassan.Aura", category: "system-audio")

    /// Most recent buffer's peak level (diagnostics / metering).
    var currentPeak: Float { peak.withLock { $0 } }

    /// Format of the delivered buffers (valid after `start()`). The tap is
    /// silent — delivers nothing — while nothing plays, so the writer uses this
    /// to synthesize silence for those gaps.
    var streamFormat: CMAudioFormatDescription? { formatDescription }

    #if DEBUG
    /// (IO callbacks, callbacks whose tap input was empty) — diagnostics.
    let debugCounts = OSAllocatedUnfairLock(initialState: (cycles: 0, empty: 0, noHostTime: 0))
    #endif

    init(excluding processObjects: [AudioObjectID], handler: @escaping Handler) {
        self.handler = handler
        excludedProcesses = processObjects
        tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: processObjects)
        tapDescription.name = "Aura – Recording"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
    }

    deinit { stop() }

    func start() throws {
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else { throw CaptureError.tap(status) }

        // The default output device provides the clock; nothing is played to it.
        let clockUID = AudioDeviceManager.shared.defaultOutputDeviceUID() ?? ""
        var description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: AppAudioRoute.aggregateUIDPrefix + "rec." + UUID().uuidString,
            kAudioAggregateDeviceNameKey: "Aura – Recording",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        if !clockUID.isEmpty {
            description[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clockUID]]
        }
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw CaptureError.aggregate(status) }

        // Describe the tapped stream for CoreMedia.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioHAL.address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        if AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &asbd) != noErr || asbd.mSampleRate == 0 {
            addr = AudioHAL.address(kAudioTapPropertyFormat)
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr else { stop(); throw CaptureError.format }
        }
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBytesPerFrame > 0 else { stop(); throw CaptureError.format }
        sampleRate = asbd.mSampleRate
        bytesPerFrame = asbd.mBytesPerFrame
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &formatDescription) == noErr else {
            stop(); throw CaptureError.format
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, input, inputTime, output, _ in
            // Never play anything to the clock device.
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            self?.deliver(input, at: inputTime)
        }
        guard status == noErr, ioProcID != nil else { stop(); throw CaptureError.ioProc(status) }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { stop(); throw CaptureError.start(status) }
        log.info("System audio capture started at \(Int(self.sampleRate)) Hz")
    }

    func stop() {
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
    }

    // MARK: - IO thread

    private func deliver(_ input: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        #if DEBUG
        let isEmpty = list.first.map { $0.mDataByteSize == 0 || $0.mData == nil } ?? true
        let noHostTime = !time.pointee.mFlags.contains(.hostTimeValid)
        debugCounts.withLock { $0.cycles += 1; if isEmpty { $0.empty += 1 }; if noHostTime { $0.noHostTime += 1 } }
        #endif
        guard let first = list.first, first.mDataByteSize > 0, let formatDescription,
              time.pointee.mFlags.contains(.hostTimeValid) else { return }

        // Level for metering/diagnostics.
        var level: Float = 0
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) { level = max(level, abs(samples[i])) }
        }
        let measured = level
        peak.withLock { $0 = measured }

        // Host-time timestamps share ScreenCaptureKit's clock, so audio lines
        // up with the video frames.
        let frames = CMItemCount(first.mDataByteSize / bytesPerFrame)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(time.pointee.mHostTime),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                                   sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer,
              CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
                                                            blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                            flags: 0, bufferList: input) == noErr else { return }
        handler(sampleBuffer)
    }
}
