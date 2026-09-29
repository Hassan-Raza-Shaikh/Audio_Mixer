@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import os

/// Records the screen and, optionally, everything you hear into one `.mov` —
/// the thing a built-in macOS screen recording can't do.
///
/// ScreenCaptureKit delivers the video frames and `SystemAudioCapture` the
/// audio (exactly what you hear, even while Aura is adjusting apps); an
/// AVAssetWriter muxes them (H.264 or HEVC + AAC). Published properties change
/// on the main thread; the writer and its inputs are only touched on
/// `writerQueue`, which is also the queue ScreenCaptureKit delivers frames on.
final class ScreenRecorder: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = ScreenRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastOutputURL: URL?

    /// Whether system audio is included. Remembered across launches.
    @Published var includeAudio: Bool = UserDefaults.standard.object(forKey: "ScreenRecordingIncludesAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeAudio, forKey: "ScreenRecordingIncludesAudio") }
    }

    private let log = Logger(subsystem: "com.hassan.Aura", category: "screen-recorder")
    private var stream: SCStream?                   // main thread
    private var systemAudio: SystemAudioCapture?    // main thread
    private var timer: Timer?
    private var startDate: Date?

    private let writerQueue = DispatchQueue(label: "com.hassan.Aura.screen-recorder")
    private var writer: AVAssetWriter?              // writerQueue
    private var videoInput: AVAssetWriterInput?     // writerQueue
    private var audioInput: AVAssetWriterInput?     // writerQueue
    private var sessionStarted = false              // writerQueue
    private var isFinishing = false                 // writerQueue
    private var audioFormat: CMAudioFormatDescription?  // writerQueue — for synthesized silence
    private var nextAudioTime = CMTime.invalid      // writerQueue — how far the audio track reaches

    enum RecorderError: LocalizedError {
        case noDisplay, cannotAddVideo
        var errorDescription: String? {
            switch self {
            case .noDisplay: "No display is available to record."
            case .cannotAddVideo: "The video encoder couldn't be set up."
            }
        }
    }

    // MARK: - Public API (main thread)

    @MainActor
    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    @MainActor
    func start() async {
        guard !isRecording, !isStarting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // The first request shows the system prompt; after a denial macOS
            // won't ask again, so point the user at System Settings.
            if !CGRequestScreenCaptureAccess() {
                AppState.shared.showNotice("Allow Aura under Privacy & Security › Screen & System Audio Recording, then try again.")
                Self.openScreenRecordingSettings()
            }
            return
        }

        isStarting = true
        defer { isStarting = false }
        let wantAudio = includeAudio

        do {
            let url = try RecordingLocation.screen.newFileURL(named: "Screen Recording \(RecordingLocation.timestamp())",
                                                                extension: "mov")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let (display, scale) = preferredDisplay(in: content) else { throw RecorderError.noDisplay }

            // Hide Aura's own windows from the video.
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

            // Encoders need even dimensions.
            let width = Int(CGFloat(display.width) * scale) & ~1
            let height = Int(CGFloat(display.height) * scale) & ~1

            // Video only: audio comes from SystemAudioCapture (see its docs for
            // why ScreenCaptureKit's audio is wrong while Aura routes apps).
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 6

            var audioCapture: SystemAudioCapture?
            if wantAudio {
                let capture = makeSystemAudioCapture()
                try capture.start()
                audioCapture = capture
                AudioRouter.shared.onRoutesChanged = { [weak self] in
                    Task { @MainActor in self?.routesChangedWhileRecording() }
                }
            }
            self.systemAudio = audioCapture

            try await prepareWriter(url: url, width: width, height: height, audioFormat: audioCapture?.streamFormat)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
            try await stream.startCapture()

            self.stream = stream
            isRecording = true
            startDate = Date()
            startTimer()
            log.info("Recording \(width)x\(height) audio=\(wantAudio) → \(url.lastPathComponent, privacy: .public)")
        } catch {
            log.error("Couldn't start recording: \(error.localizedDescription, privacy: .public)")
            stopSystemAudio()
            _ = await finishWriting(endTime: .invalid)
            AppState.shared.showNotice("Couldn't start screen recording: \(error.localizedDescription)")
        }
    }

    private func makeSystemAudioCapture() -> SystemAudioCapture {
        SystemAudioCapture(excluding: AudioRouter.shared.routedProcessObjects) { [weak self] sampleBuffer in
            self?.appendAudio(sampleBuffer)
        }
    }

    /// The user adjusted (or reset) an app mid-recording. Rebuild the audio tap
    /// so it leaves out exactly the apps Aura is now routing — a gap of a few
    /// milliseconds instead of the original and Aura's copy cancelling out.
    @MainActor
    private func routesChangedWhileRecording() {
        guard let current = systemAudio else { return }
        let routed = AudioRouter.shared.routedProcessObjects
        guard Set(routed) != Set(current.excludedProcesses) else { return }
        current.stop()
        let replacement = makeSystemAudioCapture()
        do {
            try replacement.start()
            systemAudio = replacement
        } catch {
            systemAudio = nil
            log.error("Couldn't restart recording audio: \(String(describing: error), privacy: .public)")
            AppState.shared.showNotice("The recording's audio stopped because the audio setup changed.")
        }
    }

    @MainActor
    private func stopSystemAudio() {
        AudioRouter.shared.onRoutesChanged = nil
        systemAudio?.stop()
        systemAudio = nil
    }

    @MainActor
    func stop() {
        Task { await stopAndSave() }
    }

    /// Stops capturing and waits until the movie file is finalized.
    @MainActor
    func stopAndSave() async {
        guard isRecording else { return }
        isRecording = false
        stopTimer()
        // The movie ends *now*, even if the screen hasn't changed for a while
        // (ScreenCaptureKit only delivers frames when something changes).
        let endTime = CMClockGetTime(CMClockGetHostTimeClock())
        let stream = self.stream
        self.stream = nil

        try? await stream?.stopCapture()
        stopSystemAudio()
        if let url = await finishWriting(endTime: endTime) {
            lastOutputURL = url
            AppState.shared.showNotice("Saved “\(url.lastPathComponent)”", reveal: url)
        } else {
            AppState.shared.showNotice("The screen recording couldn't be saved.")
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Writer

    /// `audioFormat == nil` means video only.
    private func prepareWriter(url: URL, width: Int, height: Int, audioFormat: CMAudioFormatDescription?) async throws {
        let format = UncheckedSendable(value: audioFormat)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerQueue.async { [self] in
                let audioFormat = format.value
                let audioSampleRate = audioFormat
                    .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
                // H.264 plays everywhere but tops out at 4096×2304; use HEVC beyond that.
                let useHEVC = width > 4096 || height > 2304
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: width * height * 3,      // crisp text without huge files
                        AVVideoExpectedSourceFrameRateKey: 60,
                        AVVideoMaxKeyFrameIntervalKey: 120,
                    ],
                ]
                // AAC at the capture's own rate (the output device's), so no resampling.
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: audioSampleRate ?? 48_000,
                    AVEncoderBitRateKey: 192_000,
                ]
                do {
                    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                    let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                    video.expectsMediaDataInRealTime = true
                    guard writer.canAdd(video) else { throw RecorderError.cannotAddVideo }
                    writer.add(video)

                    var audioInput: AVAssetWriterInput?
                    if audioSampleRate != nil {
                        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                        input.expectsMediaDataInRealTime = true
                        if writer.canAdd(input) {
                            writer.add(input)
                            audioInput = input
                        }
                    }

                    self.writer = writer
                    self.videoInput = video
                    self.audioInput = audioInput
                    self.audioFormat = audioFormat
                    self.nextAudioTime = .invalid
                    self.sessionStarted = false
                    self.isFinishing = false
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Finalizes the movie, extending it to `endTime`. Returns its URL, or nil
    /// if nothing usable was written (in which case the empty file is removed).
    private func finishWriting(endTime: CMTime) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            writerQueue.async { [self] in
                isFinishing = true
                guard let writer else {
                    resetWriter()
                    continuation.resume(returning: nil)
                    return
                }
                guard sessionStarted, writer.status == .writing else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: writer.outputURL)
                    resetWriter()
                    continuation.resume(returning: nil)
                    return
                }
                if endTime.isValid {
                    // Keep the audio track continuous to the very end, then hold
                    // the last video frame until the moment Record was stopped.
                    if audioInput != nil { appendSilence(until: endTime) }
                    writer.endSession(atSourceTime: endTime)
                }
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [self] in
                    // Completion arrives on an arbitrary thread; read the writer back on its queue.
                    writerQueue.async {
                        let finished = self.writer
                        let url = finished?.status == .completed ? finished?.outputURL : nil
                        if url == nil {
                            self.log.error("Writer failed: \(finished?.error?.localizedDescription ?? "unknown", privacy: .public)")
                        }
                        self.resetWriter()
                        continuation.resume(returning: url)
                    }
                }
            }
        }
    }

    private func resetWriter() {
        writer = nil
        videoInput = nil
        audioInput = nil
        audioFormat = nil
        nextAudioTime = .invalid
        sessionStarted = false
        isFinishing = false
    }

    /// Fills the audio track with silence from where it currently ends up to
    /// `end`. The system-audio tap delivers nothing while the Mac is silent, so
    /// without this, quiet stretches would be missing from the track (and a
    /// fully silent recording would have no audio track at all). writerQueue.
    private func appendSilence(until end: CMTime) {
        guard let format = audioFormat, let input = audioInput, nextAudioTime.isValid,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0 else { return }
        let rate = asbd.mSampleRate
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerFrame = Int(asbd.mBytesPerFrame) * (isNonInterleaved ? Int(asbd.mChannelsPerFrame) : 1)

        while CMTimeCompare(nextAudioTime, end) < 0 {
            let remaining = Int((CMTimeSubtract(end, nextAudioTime).seconds * rate).rounded(.down))
            let frames = min(remaining, Int(rate / 10))            // ≤ 100 ms per buffer
            guard frames > 0, input.isReadyForMoreMediaData,
                  let silence = Self.silentBuffer(frames: frames, bytesPerFrame: bytesPerFrame,
                                                  format: format, at: nextAudioTime),
                  input.append(silence) else { return }
            nextAudioTime = CMTimeAdd(nextAudioTime, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
        }
    }

    private static func silentBuffer(frames: Int, bytesPerFrame: Int,
                                     format: CMAudioFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        let length = frames * bytesPerFrame
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                         dataLength: length) == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    // MARK: - Helpers

    @MainActor
    private func preferredDisplay(in content: SCShareableContent) -> (SCDisplay, CGFloat)? {
        // Record the screen the user is working on (where the pointer is).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            return nil
        }
        return (display, screen?.backingScaleFactor ?? 2)
    }

    @MainActor
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    @MainActor
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
        startDate = nil
    }

    /// ScreenCaptureKit also emits "idle" frames (nothing changed) that carry no
    /// image; appending one would fail the writer, so only keep complete frames.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension ScreenRecorder: SCStreamOutput, SCStreamDelegate {
    // Runs on `writerQueue`.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !isFinishing, let writer else { return }

        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            if !sessionStarted {
                // Anchor the timeline on the first real video frame.
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStarted = true
                nextAudioTime = sampleBuffer.presentationTimeStamp     // audio track starts here too
            }
            if writer.status == .writing, let input = videoInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        default:
            break
        }
    }

    /// Called from SystemAudioCapture's IO thread; hops to the writer queue.
    fileprivate func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        let buffer = UncheckedSendable(value: sampleBuffer)
        writerQueue.async { [self] in
            // Audio before the first video frame is dropped: the timeline starts there.
            guard !isFinishing, sessionStarted, let writer, writer.status == .writing,
                  let input = audioInput else { return }
            let sample = buffer.value
            let start = sample.presentationTimeStamp
            // Silence while nothing was playing (the tap delivers nothing then).
            if CMTimeSubtract(start, nextAudioTime).seconds > 0.02 { appendSilence(until: start) }
            guard input.isReadyForMoreMediaData, input.append(sample) else { return }
            let end = CMTimeAdd(start, sample.duration)
            if CMTimeCompare(end, nextAudioTime) > 0 { nextAudioTime = end }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Stream stopped: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            if self.isRecording { self.stop() }
        }
    }
}

/// Carries a value across a concurrency boundary where ownership is handed
/// off rather than shared (e.g. a sample buffer from an audio thread to a queue).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
