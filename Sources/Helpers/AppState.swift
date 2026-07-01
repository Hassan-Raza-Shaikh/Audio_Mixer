import SwiftUI
import Combine

/// Represents an audio output device available on the system
public struct AudioDevice: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    
    public init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// Represents an application that is outputting or capable of outputting audio
public struct AudioApp: Identifiable {
    public let id: UUID = UUID()
    public let name: String
    public let bundleId: String
    public let pid: Int32
    public var volume: Double // 0.0 to 1.0
    public var isMuted: Bool
    public var isRecording: Bool
    public var pan: Double // -1.0 (Left) to 1.0 (Right)
    public var dbLevel: Float // -60.0 to 0.0
    public var accentColor: Color
    public var outputDevice: AudioDevice
    
    public init(name: String, bundleId: String, pid: Int32, volume: Double = 0.8, isMuted: Bool = false, isRecording: Bool = false, pan: Double = 0.0, dbLevel: Float = -60.0, outputDevice: AudioDevice) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
        self.volume = volume
        self.isMuted = isMuted
        self.isRecording = isRecording
        self.pan = pan
        self.dbLevel = dbLevel
        self.outputDevice = outputDevice
        
        // Generate an accent color based on the app's bundle ID/name
        if bundleId.contains("spotify") {
            self.accentColor = Color(red: 0.11, green: 0.73, blue: 0.33) // Spotify Green
        } else if bundleId.contains("zoom") || bundleId.contains("teams") {
            self.accentColor = Color(red: 0.18, green: 0.55, blue: 0.94) // Zoom Blue
        } else if bundleId.contains("safari") || bundleId.contains("chrome") {
            self.accentColor = Color(red: 0.92, green: 0.26, blue: 0.21) // Browser Red/Orange
        } else {
            self.accentColor = Color.accentColor
        }
    }
}

@MainActor
public class AppState: ObservableObject {
    public static let shared = AppState()
    
    @Published var apps: [AudioApp] = []
    @Published var devices: [AudioDevice] = []
    @Published var defaultDevice: AudioDevice?
    
    @Published var isLoopbackEnabled: Bool = false
    @Published var isAccessoryMode: Bool = true {
        didSet {
            toggleActivationPolicy()
        }
    }
    
    private init() {
        loadMockData()
    }
    
    private func loadMockData() {
        let headphones = AudioDevice(id: "dev_headphones", name: "Sony WH-1000XM4 (Bluetooth)", isDefault: false)
        let speakers = AudioDevice(id: "dev_speakers", name: "MacBook Pro Speakers (Built-in)", isDefault: true)
        let externalMonitor = AudioDevice(id: "dev_hdmi", name: "Studio Display (HDMI)", isDefault: false)
        
        self.devices = [speakers, headphones, externalMonitor]
        self.defaultDevice = speakers
        
        self.apps = [
            AudioApp(name: "Spotify", bundleId: "com.spotify.client", pid: 101, volume: 0.75, outputDevice: headphones),
            AudioApp(name: "Zoom Meeting", bundleId: "us.zoom.xos", pid: 102, volume: 0.90, outputDevice: speakers),
            AudioApp(name: "Safari", bundleId: "com.apple.Safari", pid: 103, volume: 0.50, outputDevice: speakers),
            AudioApp(name: "Discord", bundleId: "com.hnc.Discord", pid: 104, volume: 0.85, outputDevice: headphones)
        ]
        
        // Start a mock meter updates timer to make visualizers feel "alive"
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                for i in 0..<self.apps.count {
                    if !self.apps[i].isMuted {
                        // Generate dynamic meter values
                        let noise = Float.random(in: -30.0...(-5.0))
                        self.apps[i].dbLevel = noise
                    } else {
                        self.apps[i].dbLevel = -60.0
                    }
                }
            }
        }
    }
    
    public func setVolume(for app: AudioApp, to volume: Double) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].volume = volume
        }
    }
    
    public func toggleMute(for app: AudioApp) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].isMuted.toggle()
        }
    }
    
    public func toggleRecording(for app: AudioApp) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].isRecording.toggle()
        }
    }
    
    public func setOutputDevice(for app: AudioApp, to device: AudioDevice) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].outputDevice = device
        }
    }
    
    public func setPan(for app: AudioApp, to pan: Double) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].pan = pan
        }
    }
    
    private func toggleActivationPolicy() {
        if isAccessoryMode {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
