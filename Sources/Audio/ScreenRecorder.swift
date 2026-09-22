import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import AppKit
import CoreGraphics

/// Records the screen (video) and, optionally, all system audio into a single
/// `.mov` file. This is the thing macOS won't do out of the box: a screen
/// recording with the sound you actually hear baked in.
///
/// ScreenCaptureKit feeds raw video frames and PCM audio; an `AVAssetWriter`
/// muxes them into one H.264 + AAC movie. Published properties are updated on
/// the main queue for SwiftUI; the writer and its inputs are only ever touched
/// on `writerQueue`, which is also the sample-handler queue.
public final class ScreenRecorder: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = ScreenRecorder()

    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var lastOutputURL: URL?

    /// Whether to include system audio in the recording. Set from the UI.
    @Published public var includeAudio = true

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false

    private var startWallClock: Date?
    private var timer: Timer?

    private let writerQueue = DispatchQueue(label: "com.hassan.Aura.ScreenRecorder")

    /// Directory where finished recordings are saved: ~/Movies/Aura Screen Recordings
    public static var outputDirectory: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return base.appendingPathComponent("Aura Screen Recordings", isDirectory: true)
    }

    // MARK: - Public API

    public func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    public func start() async {
        guard !isRecording else { return }
        let wantAudio = includeAudio

        // Screen recording needs the Screen Recording TCC grant. If it's not
        // effective for this binary, prompt/deep-link instead of failing
        // silently so the record button doesn't just do nothing.
        guard CGPreflightScreenCaptureAccess() else {
            print("ScreenRecorder: Screen Recording permission not granted — prompting")
            CGRequestScreenCaptureAccess()
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                print("ScreenRecorder: no display available")
                return
            }

            // Exclude Aura's own windows so the mixer UI isn't in the shot and
            // our own playback isn't double-captured in the audio track.
            let auraApp = content.applications.first { $0.bundleIdentifier == "com.hassan.Aura" }
            let filter = SCContentFilter(display: display,
                                         excludingApplications: auraApp.map { [$0] } ?? [],
                                         exceptingWindows: [])

            let scale = Self.displayScaleFactor(for: display)
            let pixelWidth = Int(CGFloat(display.width) * scale)
            let pixelHeight = Int(CGFloat(display.height) * scale)

            let config = SCStreamConfiguration()
            config.width = pixelWidth
            config.height = pixelHeight
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 6
            if wantAudio {
                config.capturesAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
            }

            try setupWriter(width: pixelWidth, height: pixelHeight, withAudio: wantAudio)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
            if wantAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
            }
            try await stream.startCapture()
            self.stream = stream

            await MainActor.run {
                self.isRecording = true
                self.startWallClock = Date()
                self.startTimer()
            }
            print("ScreenRecorder: recording \(pixelWidth)x\(pixelHeight), audio=\(wantAudio)")
        } catch {
            print("ScreenRecorder: failed to start — \(error.localizedDescription)")
            try? await stream?.stopCapture()
            stream = nil
            writerQueue.async { self.cancelWriterLocked() }
        }
    }

    public func stop() {
        guard isRecording else { return }
        isRecording = false
        stopTimer()

        let stream = self.stream
        self.stream = nil
        Task {
            try? await stream?.stopCapture()
            await finishWriting()
        }
    }

    // MARK: - Writer (writerQueue only, except setup which happens-before capture)

    private func setupWriter(width: Int, height: Int, withAudio: Bool) throws {
        let dir = Self.outputDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Screen Recording \(formatter.string(from: Date())).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotAddInput }
        writer.add(videoInput)

        if withAudio {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 128_000,
            ])
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            }
        }

        self.writer = writer
        self.videoInput = videoInput
        self.sessionStarted = false
        DispatchQueue.main.async { self.lastOutputURL = url }
    }

    private func cancelWriterLocked() {
        writer?.cancelWriting()
        writer = nil
        videoInput = nil
        audioInput = nil
        sessionStarted = false
    }

    private func finishWriting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async { [weak self] in
                guard let self, let writer = self.writer, writer.status == .writing else {
                    self?.cancelWriterLocked()
                    continuation.resume(); return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                let url = writer.outputURL
                writer.finishWriting {
                    DispatchQueue.main.async {
                        self.lastOutputURL = url
                        print("ScreenRecorder: saved \(url.lastPathComponent)")
                    }
                    self.writer = nil
                    self.videoInput = nil
                    self.audioInput = nil
                    self.sessionStarted = false
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Timer (main)

    @MainActor
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startWallClock else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
        startWallClock = nil
    }

    private static func displayScaleFactor(for display: SCDisplay) -> CGFloat {
        NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2.0
    }

    enum RecorderError: Error { case cannotAddInput }
}

// MARK: - SCStreamOutput / Delegate

extension ScreenRecorder: SCStreamOutput, SCStreamDelegate {
    // Called on `writerQueue` (the sample-handler queue we registered), so it
    // may touch writer state directly without hopping actors.
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let writer = self.writer else { return }

        if writer.status == .unknown {
            // Start the session on the first video frame so audio-only samples
            // that arrive early don't anchor the timeline before there's video.
            guard type == .screen else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        guard writer.status == .writing, sessionStarted else { return }

        switch type {
        case .screen:
            if let input = videoInput, input.isReadyForMoreMediaData { input.append(sampleBuffer) }
        case .audio:
            if let input = audioInput, input.isReadyForMoreMediaData { input.append(sampleBuffer) }
        default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ScreenRecorder: stream stopped — \(error.localizedDescription)")
        Task { @MainActor in if self.isRecording { self.stop() } }
    }
}
