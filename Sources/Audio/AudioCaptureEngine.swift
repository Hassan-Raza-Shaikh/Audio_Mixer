import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreAudio

/// Thread-safe queue for buffering PCM audio packets
class AudioBufferQueue {
    private var buffers: [AVAudioPCMBuffer] = []
    private let lock = NSLock()
    private let maxBuffers = 40 // Low queue capacity to maintain low latency

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if buffers.count >= maxBuffers {
            buffers.removeFirst() // Drop oldest frame to prevent buildup/latency
        }
        buffers.append(buffer)
    }

    func dequeue() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffers.isEmpty else { return nil }
        return buffers.removeFirst()
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffers.removeAll()
    }
}

/// Represents a single active audio channel routed to an output device
class PlaybackChannel: @unchecked Sendable {
    let pid: Int32
    let queue = AudioBufferQueue()
    var sourceNode: AVAudioSourceNode?
    var deviceUID: String
    var currentFormat: AVAudioFormat?
    
    // Thread-safe parameters for the real-time render thread
    private let paramLock = NSLock()
    private var _volume: Double = 0.8
    private var _pan: Double = 0.0
    private var _isMuted: Bool = false
    private var _peak: Float = 0.0
    
    // Recording variables
    private var _isRecording: Bool = false
    var audioFile: AVAudioFile?
    
    var volume: Double {
        get { paramLock.lock(); defer { paramLock.unlock() }; return _volume }
        set { paramLock.lock(); defer { paramLock.unlock() }; _volume = newValue }
    }
    
    var pan: Double {
        get { paramLock.lock(); defer { paramLock.unlock() }; return _pan }
        set { paramLock.lock(); defer { paramLock.unlock() }; _pan = newValue }
    }
    
    var isMuted: Bool {
        get { paramLock.lock(); defer { paramLock.unlock() }; return _isMuted }
        set { paramLock.lock(); defer { paramLock.unlock() }; _isMuted = newValue }
    }
    
    var isRecording: Bool {
        get { paramLock.lock(); defer { paramLock.unlock() }; return _isRecording }
        set { paramLock.lock(); defer { paramLock.unlock() }; _isRecording = newValue }
    }
    
    var peak: Float {
        get { paramLock.lock(); defer { paramLock.unlock() }; return _peak }
        set { paramLock.lock(); defer { paramLock.unlock() }; _peak = newValue }
    }
    
    init(pid: Int32, deviceUID: String) {
        self.pid = pid
        self.deviceUID = deviceUID
    }
    
    func writeToRecordFile(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let file = audioFile else { return }
        do {
            try file.write(from: buffer)
        } catch {
            print("AudioRecorder Error: Failed to write frame to disk: \(error.localizedDescription)")
        }
    }
}

/// Manages real-time ScreenCaptureKit taps, AVAudioEngine playbacks, and CoreAudio hardware routes
public final class AudioCaptureEngine: NSObject, SCStreamOutput, @unchecked Sendable {
    public static let shared = AudioCaptureEngine()
    
    private var activeStreams: [Int32: SCStream] = [:]
    private var engines: [String: AVAudioEngine] = [:]
    private var channels: [Int32: PlaybackChannel] = [:]
    private let channelsLock = NSLock()
    
    private func getChannel(for pid: Int32) -> PlaybackChannel? {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        return channels[pid]
    }
    
    private func setChannel(_ channel: PlaybackChannel, for pid: Int32) {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        channels[pid] = channel
    }
    
    private func removeChannel(for pid: Int32) {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        channels.removeValue(forKey: pid)
    }
    
    private override init() {
        super.init()
        createMediaFolderIfNeeded()
    }
    
    private func createMediaFolderIfNeeded() {
        let mediaPath = "/Users/hassan/Media"
        if !FileManager.default.fileExists(atPath: mediaPath) {
            try? FileManager.default.createDirectory(atPath: mediaPath, withIntermediateDirectories: true, attributes: nil)
            print("Audio Mixer Setup: Created Media folder at \(mediaPath)")
        }
    }
    
    /// Returns the engine for a device, starting it if necessary
    func getEngine(for deviceUID: String) -> AVAudioEngine? {
        if let existing = engines[deviceUID] {
            return existing
        }
        
        let engine = AVAudioEngine()
        
        // Match the engine's output device to the CoreAudio hardware ID
        let audioUnit = engine.outputNode.audioUnit!
        if let deviceID = AudioDeviceManager.shared.getDeviceID(for: deviceUID) {
            var rawID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &rawID,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
            if status != noErr {
                print("CoreAudio Warning: Could not bind device \(deviceUID) to engine (Status: \(status))")
            }
        }
        
        do {
            try engine.start()
            engines[deviceUID] = engine
            print("Audio Engine: Started engine for device \(deviceUID)")
            return engine
        } catch {
            print("Audio Engine Error: Failed to start engine: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Starts capturing and playing back audio for a specific app
    public func startCapture(for pid: Int32, appName: String, deviceUID: String) {
        print("Aura Capture: Preparing real-time audio bridge for \(appName) (PID: \(pid)) -> \(deviceUID)")
        
        // Stop previous capture/playback if any
        stopCapture(for: pid)
        
        let channel = PlaybackChannel(pid: pid, deviceUID: deviceUID)
        setChannel(channel, for: pid)
        
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let runningApp = content.applications.first(where: { $0.processID == pid }) else {
                    print("Aura Capture Error: App with PID \(pid) not found in shareable content.")
                    return
                }
                
                guard let firstDisplay = content.displays.first else {
                    print("Aura Capture Error: No display found to capture.")
                    return
                }
                let filter = SCContentFilter(display: firstDisplay, including: [runningApp], exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.sampleRate = 44100
                configuration.channelCount = 2
                
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.hassan.Aura.CaptureQueue.\(pid)"))
                
                try await stream.startCapture()
                self.activeStreams[pid] = stream
                print("Aura Capture: Tap active for \(appName) (PID: \(pid))")
                
            } catch {
                print("Aura Capture Error: Failed to start SCStream for \(appName): \(error.localizedDescription)")
            }
        }
    }
    
    /// Stops capturing and tears down playback channel
    public func stopCapture(for pid: Int32) {
        if let stream = activeStreams[pid] {
            Task {
                try? await stream.stopCapture()
            }
            activeStreams.removeValue(forKey: pid)
        }
        
        if let channel = getChannel(for: pid) {
            if channel.isRecording {
                stopRecording(for: pid)
            }
            
            if let engine = engines[channel.deviceUID], let sourceNode = channel.sourceNode {
                engine.detach(sourceNode)
            }
            removeChannel(for: pid)
            print("Aura Playback: Playback channel closed for PID \(pid)")
        }
    }
    
    // MARK: - Parameters
    
    public func updateVolume(for pid: Int32, volume: Double) {
        getChannel(for: pid)?.volume = volume
    }
    
    public func updatePan(for pid: Int32, pan: Double) {
        getChannel(for: pid)?.pan = pan
    }
    
    public func updateMute(for pid: Int32, isMuted: Bool) {
        getChannel(for: pid)?.isMuted = isMuted
    }
    
    public func getPeak(for pid: Int32) -> Float {
        return getChannel(for: pid)?.peak ?? 0.0
    }
    
    public func updateRoute(for pid: Int32, deviceUID: String) {
        guard let channel = getChannel(for: pid) else { return }
        let currentVol = channel.volume
        let currentPan = channel.pan
        let currentMute = channel.isMuted
        
        // Re-setup capture stream pointing to new engine output
        startCapture(for: pid, appName: "App", deviceUID: deviceUID)
        
        // Restore values
        if let newChannel = getChannel(for: pid) {
            newChannel.volume = currentVol
            newChannel.pan = currentPan
            newChannel.isMuted = currentMute
        }
    }
    
    // MARK: - Recording
    
    public func startRecording(for pid: Int32, appName: String) {
        guard let channel = getChannel(for: pid), let format = channel.currentFormat else { return }
        
        let docPath = "/Users/hassan/Media"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateStr = formatter.string(from: Date())
        let filename = "\(appName.replacingOccurrences(of: " ", with: "_"))_\(dateStr).wav"
        let fileURL = URL(fileURLWithPath: docPath).appendingPathComponent(filename)
        
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            channel.audioFile = try AVAudioFile(forWriting: fileURL, settings: settings)
            channel.isRecording = true
            print("Aura Recorder: Recording active -> \(fileURL.path)")
        } catch {
            print("Aura Recorder Error: Could not init file: \(error.localizedDescription)")
        }
    }
    
    public func stopRecording(for pid: Int32) {
        guard let channel = getChannel(for: pid) else { return }
        channel.isRecording = false
        channel.audioFile = nil
        print("Aura Recorder: Recording stopped for PID \(pid)")
    }
    
    // MARK: - SCStreamOutput Delegate
    
    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        
        // Find PID associated with this delegate queue name (contains pid)
        let queueLabel = String(cString: __dispatch_queue_get_label(nil))
        guard let pidStr = queueLabel.components(separatedBy: ".").last, let pid = Int32(pidStr) else { return }
        
        guard let channel = getChannel(for: pid) else { return }
        
        guard let pcmBuffer = pcmBuffer(from: sampleBuffer) else { return }
        
        // Push buffer to node queue
        channel.enqueueBuffer(pcmBuffer)
    }
}

// MARK: - Audio Conversion Helpers

extension AudioCaptureEngine {
    nonisolated private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)!.pointee
        
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: AVAudioChannelCount(asbd.mChannelsPerFrame), interleaved: false)!
        
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        
        guard status == kCMBlockBufferNoErr, let rawData = dataPointer else { return nil }
        
        let channelCount = Int(asbd.mChannelsPerFrame)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let totalBytes = Int(frameCount) * bytesPerFrame
        let sizePerChannel = totalBytes / channelCount
        
        for channel in 0..<channelCount {
            let srcOffset = channel * sizePerChannel
            memcpy(buffer.floatChannelData![channel], rawData.advanced(by: srcOffset), sizePerChannel)
        }
        
        return buffer
    }
}

// MARK: - Playback Channel Audio Rendering

extension PlaybackChannel {
    func enqueueBuffer(_ buffer: AVAudioPCMBuffer) {
        self.currentFormat = buffer.format
        self.queue.enqueue(buffer)
        
        // Write to recording file if enabled
        writeToRecordFile(buffer)
        
        // Calculate peak amplitude for the real-time visualizer
        calculatePeak(from: buffer)
        
        // Initialize playback node if it doesn't exist
        if sourceNode == nil {
            let format = buffer.format
            Task {
                self.setupSourceNode(format: format)
            }
        }
    }
    
    private func calculatePeak(from buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
        var maxVal: Float = 0.0
        for channel in 0..<channelCount {
            let ptr = data[channel]
            for frame in 0..<frameCount {
                let absVal = abs(ptr[frame])
                if absVal > maxVal { maxVal = absVal }
            }
        }
        self.peak = maxVal
    }
    
    private func setupSourceNode(format: AVAudioFormat) {
        guard let engine = AudioCaptureEngine.shared.getEngine(for: deviceUID) else { return }
        
        var readOffset = 0
        var activeBuffer: AVAudioPCMBuffer? = nil
        
        let node = AVAudioSourceNode { [weak self] (isSilence, timestamp, frameCount, outputData) -> OSStatus in
            guard let self else { return noErr }
            
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let numChannels = abl.count
            let requestedFrames = Int(frameCount)
            
            var framesCopied = 0
            
            // Read parameters thread-safely
            let vol = Float(self.volume)
            let isMuted = self.isMuted
            let pan = Float(self.pan)
            
            // Mute logic
            if isMuted || vol <= 0.0001 {
                for channel in 0..<numChannels {
                    memset(abl[channel].mData, 0, requestedFrames * MemoryLayout<Float>.size)
                }
                isSilence.pointee = true
                return noErr
            }
            
            // Calculate pan weights
            let leftGain = pan > 0 ? (1.0 - pan) * vol : vol
            let rightGain = pan < 0 ? (1.0 + pan) * vol : vol
            
            while framesCopied < requestedFrames {
                if activeBuffer == nil {
                    activeBuffer = self.queue.dequeue()
                    readOffset = 0
                }
                
                guard let buf = activeBuffer else {
                    // Buffer underflow: fill remaining requested bytes with silence
                    for channel in 0..<numChannels {
                        let dest = abl[channel].mData!.assumingMemoryBound(to: Float.self).advanced(by: framesCopied)
                        let bytesToFill = (requestedFrames - framesCopied) * MemoryLayout<Float>.size
                        memset(dest, 0, bytesToFill)
                    }
                    isSilence.pointee = true
                    return noErr
                }
                
                let bufFrames = Int(buf.frameLength)
                let framesAvailable = bufFrames - readOffset
                let framesToCopy = min(requestedFrames - framesCopied, framesAvailable)
                
                for channel in 0..<numChannels {
                    let srcChannel = min(channel, Int(buf.format.channelCount) - 1)
                    let src = buf.floatChannelData![srcChannel].advanced(by: readOffset)
                    let dest = abl[channel].mData!.assumingMemoryBound(to: Float.self).advanced(by: framesCopied)
                    
                    let gain = (channel == 0) ? leftGain : rightGain
                    
                    for i in 0..<framesToCopy {
                        dest[i] = src[i] * gain
                    }
                }
                
                framesCopied += framesToCopy
                readOffset += framesToCopy
                
                if readOffset >= bufFrames {
                    activeBuffer = nil
                }
            }
            return noErr
        }
        
        self.sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        print("Audio Engine: Playback source node attached to engine.")
    }
}
