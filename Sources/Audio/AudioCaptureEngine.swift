import Foundation
import ScreenCaptureKit
import AVFoundation

/// Handles user-space application-specific audio capture using ScreenCaptureKit.
/// Isolated to MainActor to ensure thread-safe activeStreams mapping.
@MainActor
public class AudioCaptureEngine: NSObject, SCStreamOutput {
    public static let shared = AudioCaptureEngine()
    
    private var activeStreams: [Int32: SCStream] = [:]
    
    private override init() {
        super.init()
    }
    
    /// Starts capturing audio for a target application process
    public func startCapture(for pid: Int32, appName: String) {
        print("ScreenCaptureKit: Requesting audio capture stream for \(appName) (PID: \(pid))")
        
        Task {
            do {
                // Get all screen shareable content
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                
                // Find the target running application matching our PID
                guard let runningApp = content.applications.first(where: { $0.processID == pid }) else {
                    print("ScreenCaptureKit Error: Could not find application with PID \(pid)")
                    return
                }
                
                // Create a screen capture filter specifically for this application's audio
                let filter = SCContentFilter(display: content.displays.first!, including: [runningApp], exceptingWindows: [])
                
                // Configure stream to capture audio only
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                
                // Set audio properties
                configuration.sampleRate = 44100
                configuration.channelCount = 2
                
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                
                // Direct the audio stream output to our self-delegate
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.hassan.AudioMixer.CaptureQueue"))
                
                // Start stream capture
                try await stream.startCapture()
                self.activeStreams[pid] = stream
                print("ScreenCaptureKit: Capture started successfully for \(appName)")
                
            } catch {
                print("ScreenCaptureKit Exception: Failed to start audio stream capture for \(appName): \(error.localizedDescription)")
            }
        }
    }
    
    /// Stops capturing audio for a target application process
    public func stopCapture(for pid: Int32) {
        guard let stream = activeStreams[pid] else { return }
        
        Task {
            do {
                try await stream.stopCapture()
                activeStreams.removeValue(forKey: pid)
                print("ScreenCaptureKit: Stopped capture for PID \(pid)")
            } catch {
                print("ScreenCaptureKit Error: Failed to stop stream for PID \(pid): \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - SCStreamOutput Delegate
    
    /// Delegate callback from background queue. Marked nonisolated as it handles raw audio PCM calculations thread-safely.
    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        
        // Extract PCM audio levels from stream sample buffer
        calculateAudioPower(from: sampleBuffer, for: stream)
    }
    
    nonisolated private func calculateAudioPower(from sampleBuffer: CMSampleBuffer, for stream: SCStream) {
        // Access underlying block buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
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
        
        guard status == kCMBlockBufferNoErr, let rawData = dataPointer else { return }
        
        // Cast raw buffer memory to Float samples (ScreenCaptureKit default audio format)
        let sampleCount = totalLength / MemoryLayout<Float>.size
        let floatBuffer = rawData.withMemoryRebound(to: Float.self, capacity: sampleCount) { ptr in
            UnsafeBufferPointer(start: ptr, count: sampleCount)
        }
        
        // Calculate Root Mean Square (RMS) amplitude
        var sumSquares: Float = 0.0
        for sample in floatBuffer {
            sumSquares += sample * sample
        }
        
        let rms = sampleCount > 0 ? sqrt(sumSquares / Float(sampleCount)) : 0.0
        
        // Convert to decibels (dB FS, capped between -60dB and 0dB)
        let db = rms > 0.000001 ? 20.0 * log10(rms) : -60.0
        let _ = max(-60.0, min(0.0, db))
        
        // Update AppState metrics for the corresponding app
        // (In a complete app, we map the stream to its corresponding PID)
    }
}
