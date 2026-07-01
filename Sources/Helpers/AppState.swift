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
    
    /// Short display name (truncated for compact UI)
    public var shortName: String {
        let parts = name.components(separatedBy: " ")
        if parts.count > 2 { return parts.prefix(2).joined(separator: " ") }
        return name
    }
}

/// Apps that are known to produce audio, shown with priority
private let knownAudioBundleIds: [String] = [
    "com.spotify.client", "com.apple.Music", "com.apple.podcasts",
    "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
    "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
    "com.brave.Browser", "com.microsoft.edgemac",
    "com.apple.FaceTime", "com.discord.Discord", "com.hnc.Discord",
    "com.apple.QuickTimePlayerX", "io.mpv", "com.colliderli.iina",
    "com.apple.TV", "com.apple.music", "com.tidal.desktop",
    "com.netflix.Netflix", "com.amazon.PrimeVideo"
]

/// Represents an application that is outputting or capable of outputting audio
public struct AudioApp: Identifiable {
    public let id: UUID = UUID()
    public let name: String
    public let bundleId: String
    public let pid: Int32
    public var icon: NSImage?
    public var volume: Double       // 0.0 to 1.0
    public var isMuted: Bool
    public var isRecording: Bool
    public var stereoPosition: Double  // -1.0 (Left) to 1.0 (Right)
    public var dbLevel: Float       // -60.0 to 0.0
    public var accentColor: Color
    public var outputDevice: AudioDevice
    public var isKnownAudioApp: Bool
    
    // Spatial canvas position (set by auto-layout or drag)
    public var canvasX: Double = 0.5   // 0.0 to 1.0 normalized
    public var canvasY: Double = 0.3   // 0.0 to 1.0 normalized
    
    public init(name: String, bundleId: String, pid: Int32, icon: NSImage? = nil,
                volume: Double = 0.8, isMuted: Bool = false, isRecording: Bool = false,
                stereoPosition: Double = 0.0, dbLevel: Float = -60.0,
                outputDevice: AudioDevice, canvasX: Double = 0.5, canvasY: Double = 0.3) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
        self.icon = icon
        self.volume = volume
        self.isMuted = isMuted
        self.isRecording = isRecording
        self.stereoPosition = stereoPosition
        self.dbLevel = dbLevel
        self.outputDevice = outputDevice
        self.canvasX = canvasX
        self.canvasY = canvasY
        self.isKnownAudioApp = knownAudioBundleIds.contains(bundleId) ||
            knownAudioBundleIds.contains(where: { bundleId.hasPrefix($0) })
        
        // Generate accent color from bundle ID
        if bundleId.contains("spotify") || bundleId.contains("music") || bundleId.contains("tidal") {
            self.accentColor = Color(red: 0.11, green: 0.73, blue: 0.33)
        } else if bundleId.contains("zoom") || bundleId.contains("teams") || bundleId.contains("facetime") {
            self.accentColor = Color(red: 0.18, green: 0.55, blue: 0.94)
        } else if bundleId.contains("chrome") || bundleId.contains("brave") {
            self.accentColor = Color(red: 0.92, green: 0.26, blue: 0.21)
        } else if bundleId.contains("safari") {
            self.accentColor = Color(red: 0.0, green: 0.48, blue: 1.0)
        } else if bundleId.contains("discord") {
            self.accentColor = Color(red: 0.35, green: 0.40, blue: 0.93)
        } else if bundleId.contains("firefox") {
            self.accentColor = Color(red: 1.0, green: 0.40, blue: 0.0)
        } else if bundleId.contains("netflix") {
            self.accentColor = Color(red: 0.90, green: 0.10, blue: 0.10)
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
    @Published var showAllApps: Bool = false  // toggle to show/hide non-audio apps
    
    private var appCounter: Int = 0  // for circular layout
    
    private init() {
        loadInitialState()
    }
    
    private func loadInitialState() {
        let fetchedDevices = AudioDeviceManager.shared.fetchOutputDevices()
        self.devices = fetchedDevices
        self.defaultDevice = fetchedDevices.first(where: { $0.isDefault }) ?? fetchedDevices.first
        
        updateRunningApps()
        
        // Refresh app list every second
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.updateRunningApps() }
        }
        
        // Simulate audio level meters
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                for i in 0..<self.apps.count {
                    guard !self.apps[i].isMuted else {
                        self.apps[i].dbLevel = -60.0
                        continue
                    }
                    // Known audio apps get realistic activity; others stay quiet
                    if self.apps[i].isKnownAudioApp {
                        self.apps[i].dbLevel = Float.random(in: -18.0...(-3.0))
                    } else {
                        // Random occasional "blips" for background apps
                        let dice = Float.random(in: 0...1)
                        self.apps[i].dbLevel = dice > 0.85 ? Float.random(in: -40.0...(-20.0)) : -60.0
                    }
                }
            }
        }
    }
    
    private func updateRunningApps() {
        let workspace = NSWorkspace.shared
        // Only show regular apps (have Dock icons)
        let runningApps = workspace.runningApplications.filter {
            $0.activationPolicy == .regular &&
            $0.bundleIdentifier != "com.hassan.AudioMixer"
        }
        
        let defaultOutput = self.defaultDevice ?? AudioDevice(id: "default", name: "System Default")
        let existingCount = self.apps.count
        
        var newApps: [AudioApp] = []
        for app in runningApps {
            guard let name = app.localizedName,
                  let bundleId = app.bundleIdentifier else { continue }
            
            if let existing = self.apps.first(where: { $0.pid == app.processIdentifier }) {
                newApps.append(existing)
            } else {
                // New app: place it at the next circular layout position
                let (cx, cy) = circularPosition(for: newApps.count + existingCount)
                let newApp = AudioApp(
                    name: name, bundleId: bundleId,
                    pid: app.processIdentifier,
                    icon: app.icon,
                    volume: 0.8,
                    outputDevice: defaultOutput,
                    canvasX: cx,
                    canvasY: cy
                )
                newApps.append(newApp)
            }
        }
        
        // Sort: known audio apps first, then alphabetically
        self.apps = newApps.sorted {
            if $0.isKnownAudioApp != $1.isKnownAudioApp { return $0.isKnownAudioApp }
            return $0.name < $1.name
        }
    }
    
    /// Evenly distributes app nodes in a circle around the center of the canvas
    private func circularPosition(for index: Int) -> (Double, Double) {
        let total = max(1, NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.count)
        let angle = (Double(index) / Double(total)) * 2 * .pi - .pi / 2
        let radius = 0.32  // fraction of canvas
        let cx = 0.5 + radius * cos(angle)
        let cy = 0.5 + radius * sin(angle)
        return (cx, cy)
    }
    
    // MARK: - Public Mutators
    
    public func setVolume(for app: AudioApp, to volume: Double) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) {
            apps[i].volume = volume
        }
    }
    
    public func toggleMute(for app: AudioApp) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) {
            apps[i].isMuted.toggle()
        }
    }
    
    public func toggleRecording(for app: AudioApp) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) {
            apps[i].isRecording.toggle()
        }
    }
    
    public func setOutputDevice(for app: AudioApp, to device: AudioDevice) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) {
            apps[i].outputDevice = device
        }
    }
    
    public func setStereoPosition(for app: AudioApp, to position: Double) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) {
            apps[i].stereoPosition = position
        }
    }
    
    public func setCanvasPosition(for app: AudioApp, x: Double, y: Double) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) {
            apps[i].canvasX = x
            apps[i].canvasY = y
        }
    }
    
    public func snapToCenter(for app: AudioApp) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) {
            apps[i].stereoPosition = 0.0
            apps[i].volume = 0.8
            let (cx, cy) = circularPosition(for: i)
            apps[i].canvasX = cx
            apps[i].canvasY = cy
        }
    }
    
    public func resetToDefaults() {
        let defaultDev = defaultDevice ?? devices.first
        let total = apps.count
        for i in 0..<apps.count {
            apps[i].volume = 0.8
            apps[i].isMuted = false
            apps[i].stereoPosition = 0.0
            if let dev = defaultDev { apps[i].outputDevice = dev }
            // Re-layout in circle
            let angle = (Double(i) / Double(max(1, total))) * 2 * .pi - .pi / 2
            let radius = 0.32
            apps[i].canvasX = 0.5 + radius * cos(angle)
            apps[i].canvasY = 0.5 + radius * sin(angle)
        }
    }
    
    /// Visible apps depending on the showAllApps toggle
    public var visibleApps: [AudioApp] {
        if showAllApps { return apps }
        // Show known audio apps + apps that are recently active
        return apps.filter { $0.isKnownAudioApp || $0.dbLevel > -50 }
    }
}
