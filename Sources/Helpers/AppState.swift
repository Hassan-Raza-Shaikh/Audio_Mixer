import SwiftUI
import Combine

// MARK: - Audio Device

public struct AudioDevice: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    
    public init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
    
    public var shortName: String {
        let parts = name.components(separatedBy: " ")
        if parts.count > 2 { return parts.prefix(2).joined(separator: " ") }
        return name
    }
}

// MARK: - Known Audio Apps

private let knownAudioBundlePrefixes: [String] = [
    "com.spotify.client", "com.apple.Music", "com.apple.music",
    "com.apple.podcasts", "com.apple.TV",
    "us.zoom.xos",
    "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
    "com.brave.Browser", "com.microsoft.edgemac",
    "com.apple.FaceTime", "com.discord", "com.hnc.Discord",
    "com.apple.QuickTimePlayerX", "io.mpv", "com.colliderli.iina",
    "com.tidal.desktop", "com.netflix", "com.amazon.PrimeVideo"
]

// MARK: - Audio App

public struct AudioApp: Identifiable {
    public let id: Int32
    public let name: String
    public let bundleId: String
    public let pid: Int32
    public var icon: NSImage?
    public var volume: Double = 0.8
    public var isMuted: Bool = false
    public var isRecording: Bool = false
    public var stereoPosition: Double = 0.0
    public var accentColor: Color = .accentColor
    public var outputDevice: AudioDevice
    public var isKnownAudioApp: Bool = false
    public var canvasX: Double = 0.5
    public var canvasY: Double = 0.5
    public var isSpatialEnabled: Bool = false

    public init(name: String, bundleId: String, pid: Int32, icon: NSImage? = nil,
                volume: Double = 0.8, stereoPosition: Double = 0.0,
                outputDevice: AudioDevice,
                canvasX: Double = 0.5, canvasY: Double = 0.5,
                isSpatialEnabled: Bool = false) {
        self.id = pid
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
        self.icon = icon
        self.volume = volume
        self.stereoPosition = stereoPosition
        self.outputDevice = outputDevice
        self.canvasX = canvasX
        self.canvasY = canvasY
        self.isKnownAudioApp = knownAudioBundlePrefixes.contains(where: { bundleId.hasPrefix($0) })
        self.isSpatialEnabled = isSpatialEnabled

        let b = bundleId.lowercased()
        if b.contains("spotify") || b.contains("music") || b.contains("tidal") {
            self.accentColor = Color(red: 0.11, green: 0.73, blue: 0.33)
        } else if b.contains("zoom") || b.contains("facetime") {
            self.accentColor = Color(red: 0.18, green: 0.55, blue: 0.94)
        } else if b.contains("chrome") || b.contains("brave") {
            self.accentColor = Color(red: 0.92, green: 0.26, blue: 0.21)
        } else if b.contains("safari") {
            self.accentColor = Color(red: 0.0, green: 0.48, blue: 1.0)
        } else if b.contains("discord") {
            self.accentColor = Color(red: 0.35, green: 0.40, blue: 0.93)
        } else if b.contains("firefox") {
            self.accentColor = Color(red: 1.0, green: 0.40, blue: 0.0)
        } else if b.contains("netflix") {
            self.accentColor = Color(red: 0.90, green: 0.10, blue: 0.10)
        }
    }
}

// MARK: - App State

@MainActor
public class AppState: ObservableObject {
    public static let shared = AppState()

    @Published var apps: [AudioApp] = []
    @Published var devices: [AudioDevice] = []
    @Published var defaultDevice: AudioDevice?
    @Published var isLoopbackEnabled: Bool = false {
        didSet {
            handleLoopbackToggle(isEnabled: isLoopbackEnabled)
        }
    }
    @Published var showAllApps: Bool = true
    @Published var activeTab: String = "mixer" // "mixer" or "spatial"

    private var originalDefaultDevice: AudioDevice?

    private init() {
        loadInitialState()
    }

    private func loadInitialState() {
        let fetched = AudioDeviceManager.shared.fetchOutputDevices()
        self.devices = fetched
        self.defaultDevice = fetched.first(where: { $0.isDefault }) ?? fetched.first
        updateRunningApps()
        
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.updateRunningApps() }
        }
    }

    private func updateRunningApps() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular &&
            $0.bundleIdentifier != nil &&
            $0.bundleIdentifier != "com.hassan.Aura"
        }

        let defaultOutput = self.defaultDevice ?? AudioDevice(id: "default", name: "System Default")
        let existingPIDs = Set(self.apps.map { $0.pid })
        let runningPIDs  = Set(running.map  { $0.processIdentifier })

        // Stop capture for apps that closed
        for oldApp in self.apps {
            if !runningPIDs.contains(oldApp.pid) {
                AudioCaptureEngine.shared.stopCapture(for: oldApp.pid)
            }
        }

        var updatedApps = self.apps.filter { runningPIDs.contains($0.pid) }

        let totalForLayout = running.count
        for app in running {
            guard !existingPIDs.contains(app.processIdentifier) else { continue }
            guard let name = app.localizedName, let bundleId = app.bundleIdentifier else { continue }

            let idx = updatedApps.count
            let (cx, cy) = Self.circularPosition(for: idx, total: totalForLayout)

            // Start capture ONLY if it's a known audio app to avoid startup deadlocks on non-audio system apps
            let isKnown = knownAudioBundlePrefixes.contains(where: { bundleId.hasPrefix($0) })
            if isKnown {
                AudioCaptureEngine.shared.startCapture(for: app.processIdentifier, appName: name, deviceUID: defaultOutput.id)
            }

            // Spawns with standard center balance, default volume, spatial disabled
            let newApp = AudioApp(
                name: name, bundleId: bundleId,
                pid: app.processIdentifier,
                icon: app.icon,
                volume: 0.8,
                stereoPosition: 0.0,
                outputDevice: defaultOutput,
                canvasX: cx, canvasY: cy,
                isSpatialEnabled: false
            )
            updatedApps.append(newApp)
        }

        updatedApps.sort {
            if $0.isKnownAudioApp != $1.isKnownAudioApp { return $0.isKnownAudioApp }
            return $0.name < $1.name
        }
        self.apps = updatedApps
    }

    static func circularPosition(for index: Int, total: Int) -> (Double, Double) {
        let n = max(1, total)
        let angle = (Double(index) / Double(n)) * 2.0 * .pi - .pi / 2.0
        let radius = 0.30
        return (0.5 + radius * cos(angle), 0.5 + radius * sin(angle))
    }

    // MARK: - Loopback Auto-Routing

    private func handleLoopbackToggle(isEnabled: Bool) {
        if isEnabled {
            // Find a virtual device (Microsoft Teams Audio or BlackHole or Soundflower)
            if let virtualDevice = devices.first(where: {
                let n = $0.name.lowercased()
                return n.contains("teams") || n.contains("blackhole") || n.contains("soundflower") || n.contains("loopback")
            }) {
                // Store current physical default output
                if let currentDefault = defaultDevice, !currentDefault.id.contains("teams") && !currentDefault.id.contains("blackhole") {
                    originalDefaultDevice = currentDefault
                }
                
                // Redirect system default to virtual loopback device
                AudioDeviceManager.shared.setDefaultOutputDevice(deviceID: virtualDevice)
                print("Aura Loopback: Redirected system default output to virtual device: \(virtualDevice.name)")
            } else {
                print("Aura Loopback Warning: No virtual audio loopback device found on this system.")
            }
        } else {
            // Restore original physical default output
            if let restoreDev = originalDefaultDevice {
                AudioDeviceManager.shared.setDefaultOutputDevice(deviceID: restoreDev)
                print("Aura Loopback: Restored system default output to: \(restoreDev.name)")
            }
        }
        
        // Refresh device list to update isDefault attributes
        let fetched = AudioDeviceManager.shared.fetchOutputDevices()
        self.devices = fetched
        self.defaultDevice = fetched.first(where: { $0.isDefault }) ?? fetched.first
    }

    // MARK: - Mutators

    private func ensureCaptureStarted(for app: AudioApp) {
        AudioCaptureEngine.shared.startCapture(for: app.pid, appName: app.name, deviceUID: app.outputDevice.id)
    }

    public func setCanvasPosition(for app: AudioApp, x: Double, y: Double) {
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[i].canvasX = x
        apps[i].canvasY = y
        
        // Coupling only updates volume/balance if spatial mode is actively enabled
        if apps[i].isSpatialEnabled {
            ensureCaptureStarted(for: apps[i])
            let volume = max(0, min(1, 1.0 - y))
            let stereo = (x - 0.5) * 2.0
            apps[i].volume         = volume
            apps[i].stereoPosition = stereo
            
            AudioCaptureEngine.shared.updateVolume(for: app.pid, volume: volume)
            AudioCaptureEngine.shared.updatePan(for: app.pid, pan: stereo)
        }
    }

    public func setVolume(for app: AudioApp, to volume: Double) {
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        ensureCaptureStarted(for: apps[i])
        apps[i].volume  = volume
        apps[i].canvasY = 1.0 - volume
        AudioCaptureEngine.shared.updateVolume(for: app.pid, volume: volume)
    }

    public func setStereoPosition(for app: AudioApp, to pos: Double) {
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        ensureCaptureStarted(for: apps[i])
        apps[i].stereoPosition = pos
        apps[i].canvasX = (pos / 2.0) + 0.5
        AudioCaptureEngine.shared.updatePan(for: app.pid, pan: pos)
    }

    public func toggleMute(for app: AudioApp) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) {
            ensureCaptureStarted(for: apps[i])
            apps[i].isMuted.toggle()
            AudioCaptureEngine.shared.updateMute(for: app.pid, isMuted: apps[i].isMuted)
        }
    }
    
    public func toggleRecording(for app: AudioApp) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) {
            ensureCaptureStarted(for: apps[i])
            apps[i].isRecording.toggle()
            if apps[i].isRecording {
                AudioCaptureEngine.shared.startRecording(for: app.pid, appName: app.name)
            } else {
                AudioCaptureEngine.shared.stopRecording(for: app.pid)
            }
        }
    }
    
    public func setOutputDevice(for app: AudioApp, to device: AudioDevice) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) {
            ensureCaptureStarted(for: apps[i])
            apps[i].outputDevice = device
            AudioCaptureEngine.shared.updateRoute(for: app.pid, deviceUID: device.id)
        }
    }

    public func toggleSpatial(for app: AudioApp) {
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[i].isSpatialEnabled.toggle()
        
        // When enabling spatial, immediately couple settings to canvas coordinates
        if apps[i].isSpatialEnabled {
            ensureCaptureStarted(for: apps[i])
            let volume = max(0, min(1, 1.0 - apps[i].canvasY))
            let stereo = (apps[i].canvasX - 0.5) * 2.0
            apps[i].volume         = volume
            apps[i].stereoPosition = stereo
            
            AudioCaptureEngine.shared.updateVolume(for: app.pid, volume: volume)
            AudioCaptureEngine.shared.updatePan(for: app.pid, pan: stereo)
        }
    }

    public func snapToCenter(for app: AudioApp) {
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        ensureCaptureStarted(for: apps[i])
        apps[i].stereoPosition = 0.0
        apps[i].volume         = 0.8
        apps[i].canvasX        = 0.5
        apps[i].canvasY        = 1.0 - 0.8
        
        AudioCaptureEngine.shared.updateVolume(for: app.pid, volume: 0.8)
        AudioCaptureEngine.shared.updatePan(for: app.pid, pan: 0.0)
    }

    public func resetToDefaults() {
        let defaultDev = defaultDevice ?? devices.first
        let total = apps.count
        for i in 0..<apps.count {
            if let dev = defaultDev {
                apps[i].outputDevice = dev
                AudioCaptureEngine.shared.updateRoute(for: apps[i].pid, deviceUID: dev.id)
            }
            apps[i].isMuted          = false
            apps[i].isSpatialEnabled = false
            apps[i].volume           = 0.8
            apps[i].stereoPosition   = 0.0
            
            AudioCaptureEngine.shared.updateVolume(for: apps[i].pid, volume: 0.8)
            AudioCaptureEngine.shared.updatePan(for: apps[i].pid, pan: 0.0)
            AudioCaptureEngine.shared.updateMute(for: apps[i].pid, isMuted: false)
            
            let (cx, cy) = Self.circularPosition(for: i, total: total)
            apps[i].canvasX        = cx
            apps[i].canvasY        = cy
        }
    }

    public var visibleApps: [AudioApp] {
        if showAllApps { return apps }
        return apps.filter { $0.isKnownAudioApp }
    }
}
