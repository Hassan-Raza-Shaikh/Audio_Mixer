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

    public init(name: String, bundleId: String, pid: Int32, icon: NSImage? = nil,
                volume: Double = 0.8, stereoPosition: Double = 0.0,
                outputDevice: AudioDevice,
                canvasX: Double = 0.5, canvasY: Double = 0.5) {
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
    @Published var isLoopbackEnabled: Bool = false
    @Published var showAllApps: Bool = true

    private init() {
        loadInitialState()
    }

    private func loadInitialState() {
        let fetched = AudioDeviceManager.shared.fetchOutputDevices()
        self.devices = fetched
        self.defaultDevice = fetched.first(where: { $0.isDefault }) ?? fetched.first
        updateRunningApps()
        // Refresh every 2s only to catch newly opened/closed apps.
        // No high-frequency timers — all activity animation is pure view-layer.
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

        var updatedApps = self.apps.filter { runningPIDs.contains($0.pid) }

        let totalForLayout = running.count
        for app in running {
            guard !existingPIDs.contains(app.processIdentifier) else { continue }
            guard let name = app.localizedName, let bundleId = app.bundleIdentifier else { continue }

            let idx = updatedApps.count
            let (cx, cy) = Self.circularPosition(for: idx, total: totalForLayout)

            // Position IS state: Y drives volume, X drives stereo
            let derivedVolume = max(0, min(1, 1.0 - cy))
            let derivedStereo = (cx - 0.5) * 2.0

            let newApp = AudioApp(
                name: name, bundleId: bundleId,
                pid: app.processIdentifier,
                icon: app.icon,
                volume: derivedVolume,
                stereoPosition: derivedStereo,
                outputDevice: defaultOutput,
                canvasX: cx, canvasY: cy
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

    // MARK: - Mutators — all keep canvas ↔ audio in sync

    public func setCanvasPosition(for app: AudioApp, x: Double, y: Double) {
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[i].canvasX        = x
        apps[i].canvasY        = y
        apps[i].volume         = max(0, min(1, 1.0 - y))
        apps[i].stereoPosition = (x - 0.5) * 2.0
    }

    public func setVolume(for app: AudioApp, to volume: Double) {
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[i].volume  = volume
        apps[i].canvasY = 1.0 - volume
    }

    public func setStereoPosition(for app: AudioApp, to pos: Double) {
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[i].stereoPosition = pos
        apps[i].canvasX = (pos / 2.0) + 0.5
    }

    public func toggleMute(for app: AudioApp) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].isMuted.toggle() }
    }
    public func toggleRecording(for app: AudioApp) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].isRecording.toggle() }
    }
    public func setOutputDevice(for app: AudioApp, to device: AudioDevice) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].outputDevice = device }
    }

    public func snapToCenter(for app: AudioApp) {
        guard let i = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[i].stereoPosition = 0.0
        apps[i].volume         = 0.8
        apps[i].canvasX        = 0.5
        apps[i].canvasY        = 1.0 - 0.8   // 0.2 → near top → loud
    }

    public func selectApp(_ app: AudioApp) -> Int32 { app.id }

    public func resetToDefaults() {
        let defaultDev = defaultDevice ?? devices.first
        let total = apps.count
        for i in 0..<apps.count {
            if let dev = defaultDev { apps[i].outputDevice = dev }
            apps[i].isMuted = false
            let (cx, cy) = Self.circularPosition(for: i, total: total)
            apps[i].canvasX        = cx
            apps[i].canvasY        = cy
            apps[i].volume         = max(0, min(1, 1.0 - cy))
            apps[i].stereoPosition = (cx - 0.5) * 2.0
        }
    }

    public var visibleApps: [AudioApp] {
        if showAllApps { return apps }
        return apps.filter { $0.isKnownAudioApp }
    }
}
