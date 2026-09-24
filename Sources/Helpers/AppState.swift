import AppKit
import CoreAudio
import SwiftUI
import os

// MARK: - Audio App

/// A running app as shown in the mixer, plus the user's settings for it.
struct AudioApp: Identifiable, Equatable {
    let id: pid_t                       // main process ID
    let name: String
    let bundleID: String
    let icon: NSImage?
    let accentColor: Color

    // User settings
    var volume: Double = 1.0            // 1.0 = unchanged
    var isMuted = false
    var stereoPosition: Double = 0      // -1 (L) … +1 (R)
    var outputDeviceUID: String?        // nil = follow the system default output
    var isRecording = false

    // Live audio activity reported by Core Audio
    var audioProcessObjects: [AudioObjectID] = []
    var isPlaying = false
    var hasAudio: Bool { !audioProcessObjects.isEmpty }

    // Spatial soundstage placement (0…1 in both axes)
    var canvasX = 0.5
    var canvasY = 0.5
    var isSpatialEnabled = false

    var pid: pid_t { id }

    var mix: AppAudioRoute.Mix {
        .init(volume: Float(volume), pan: Float(stereoPosition), muted: isMuted)
    }

    init(running app: NSRunningApplication) {
        id = app.processIdentifier
        bundleID = app.bundleIdentifier ?? ""
        name = app.localizedName ?? bundleID
        icon = app.icon
        accentColor = Self.accentColor(for: bundleID)
    }

    private static func accentColor(for bundleID: String) -> Color {
        let b = bundleID.lowercased()
        if b.contains("spotify") || b.contains("music") || b.contains("tidal") { return Color(red: 0.11, green: 0.73, blue: 0.33) }
        if b.contains("zoom") || b.contains("facetime") || b.contains("teams") { return Color(red: 0.18, green: 0.55, blue: 0.94) }
        if b.contains("chrome") || b.contains("brave") { return Color(red: 0.92, green: 0.26, blue: 0.21) }
        if b.contains("safari") { return Color(red: 0.0, green: 0.48, blue: 1.0) }
        if b.contains("discord") { return Color(red: 0.35, green: 0.40, blue: 0.93) }
        if b.contains("firefox") { return Color(red: 1.0, green: 0.40, blue: 0.0) }
        if b.contains("netflix") { return Color(red: 0.90, green: 0.10, blue: 0.10) }
        return .accentColor
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var devices: [AudioDevice] = []
    @Published var showAllApps = false
    @Published var activeTab = "mixer"          // "mixer" or "spatial"

    /// Routed apps are playing but Aura only receives silence — the telltale
    /// sign that System Audio Recording access hasn't been granted.
    @Published private(set) var audioAccessLikelyDenied = false

    /// A short message for the user (errors, "saved" confirmations).
    @Published var notice: Notice?

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var revealURL: URL?
    }

    var defaultDevice: AudioDevice? { devices.first(where: \.isDefault) }

    /// "Audio" filter: apps that have opened an audio connection (or that Aura
    /// is already controlling). "All" shows every regular app.
    var visibleApps: [AudioApp] {
        showAllApps ? apps : apps.filter { $0.hasAudio || router.isRouting($0.id) }
    }

    private let router = AudioRouter.shared
    private let log = Logger(subsystem: "com.hassan.Aura", category: "state")
    /// Apps the user adjusted before they'd opened audio; routed once they do.
    private var pendingRoutes = Set<pid_t>()
    private var bundlePathCache: [pid_t: String?] = [:]
    private var processIdentityCache: [AudioObjectID: AudioHAL.ProcessIdentity] = [:]
    private var cachedRunningPIDs: [pid_t] = []
    private var cachedRegularApps: [NSRunningApplication] = []
    private var silentPolls = 0
    private var hasHeardRoutedAudio = false
    private var noticeTask: Task<Void, Never>?
    private var pollTimer: Timer?

    private init() {
        refreshDevices()
        refreshApps()

        AudioDeviceManager.shared.observeChanges { [weak self] in
            Task { @MainActor in self?.devicesDidChange() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshApps() }
            }
        }
        // Audio activity (which apps are playing, helper processes coming and
        // going) has no single notification, so poll it cheaply.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshApps() }
        }
    }

    // MARK: - Devices

    func refreshDevices() {
        let fresh = AudioDeviceManager.shared.outputDevices()
        if fresh != devices { devices = fresh }
    }

    func setSystemOutput(_ device: AudioDevice) {
        AudioDeviceManager.shared.setDefaultOutputDevice(uid: device.id)
        refreshDevices()
    }

    /// The device an app is (or would be) playing through.
    func effectiveOutput(for app: AudioApp) -> AudioDevice? {
        if let uid = app.outputDeviceUID, let device = devices.first(where: { $0.id == uid }) { return device }
        return defaultDevice
    }

    private func devicesDidChange() {
        let previous = devices
        let previousDefault = defaultDevice?.id
        refreshDevices()
        // Our own private routing devices also trigger this notification but
        // are filtered out of `devices`, so an unchanged list means nothing to do.
        guard devices != previous else { return }

        let available = Set(devices.map(\.id))
        let defaultChanged = defaultDevice?.id != previousDefault
        for app in apps {
            var needsReroute = defaultChanged && app.outputDeviceUID == nil
            if let uid = app.outputDeviceUID, !available.contains(uid), let i = index(of: app.id) {
                apps[i].outputDeviceUID = nil       // device unplugged → follow the default
                needsReroute = true
            }
            if needsReroute && router.isRouting(app.id) { applyRouting(app.id) }
        }
    }

    // MARK: - Running apps & audio processes

    func refreshApps() {
        let running = regularApps()
        let owned = attribute(AudioHAL.audioProcesses(identityCache: &processIdentityCache), to: running)
        let existing = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var updated: [AudioApp] = []
        var processesChanged: [pid_t] = []
        for runningApp in running {
            let pid = runningApp.processIdentifier
            var app = existing[pid] ?? AudioApp(running: runningApp)
            let processes = owned[pid] ?? []
            let objects = processes.map(\.objectID).sorted()
            if objects != app.audioProcessObjects {
                app.audioProcessObjects = objects
                processesChanged.append(pid)
            }
            app.isPlaying = processes.contains(where: \.isRunningOutput)
            updated.append(app)
        }

        let stillRunning = Set(updated.map(\.id))
        for gone in apps where !stillRunning.contains(gone.id) {
            router.stopRoute(gone.id)
            pendingRoutes.remove(gone.id)
        }

        // Stable order: apps that use audio first, then by name. (Sorting by
        // "currently playing" would make rows jump around under the cursor.)
        updated.sort {
            ($0.hasAudio ? 0 : 1, $0.name.localizedLowercase) < ($1.hasAudio ? 0 : 1, $1.name.localizedLowercase)
        }
        if updated.map(\.id) != apps.map(\.id) { Self.layOutSoundstage(&updated) }
        if updated != apps { apps = updated }

        // Routes follow the app's audio process tree as helpers come and go.
        for pid in processesChanged where router.isRouting(pid) || pendingRoutes.contains(pid) {
            applyRouting(pid)
        }
        syncRecordingState()
        updateAudioAccessHeuristic()
    }

    /// Running apps with a Dock presence. Checking `activationPolicy` costs an
    /// IPC per app, so the filtered list is reused until the set of running
    /// processes changes.
    private func regularApps() -> [NSRunningApplication] {
        let all = NSWorkspace.shared.runningApplications
        let pids = all.map(\.processIdentifier)
        if pids == cachedRunningPIDs { return cachedRegularApps }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        cachedRunningPIDs = pids
        cachedRegularApps = all.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != ownPID
        }
        return cachedRegularApps
    }

    /// Maps Core Audio processes to the regular app that owns them. Browsers,
    /// Electron apps and WebKit play sound from helper processes, so matching
    /// only the app's own PID would capture silence.
    private func attribute(_ processes: [AudioProcess], to running: [NSRunningApplication]) -> [pid_t: [AudioProcess]] {
        struct Owner { let pid: pid_t; let bundleID: String; let bundlePath: String }
        let owners: [Owner] = running.compactMap { app in
            guard let id = app.bundleIdentifier, let path = app.bundleURL?.path else { return nil }
            return Owner(pid: app.processIdentifier, bundleID: id, bundlePath: path + "/")
        }
        let ownerByPID = Dictionary(owners.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        var result: [pid_t: [AudioProcess]] = [:]
        var seen = Set<pid_t>()
        for process in processes where process.pid > 0 {
            seen.insert(process.pid)
            let owner = ownerByPID[process.pid]
                // Helper app inside the owner's bundle (Chrome, Electron, Teams…)
                ?? bundlePath(for: process.pid).flatMap { path in owners.first { path.hasPrefix($0.bundlePath) } }
                // Helper identified by bundle ID, e.g. com.google.Chrome.helper
                ?? owners.first { !process.bundleID.isEmpty && process.bundleID.hasPrefix($0.bundleID + ".") }
                // System process that renders audio on an app's behalf
                ?? Self.sharedAudioHosts.lazy.compactMap { prefix, host in
                    process.bundleID.hasPrefix(prefix) ? owners.first { $0.bundleID == host } : nil
                }.first
            if let owner { result[owner.pid, default: []].append(process) }
        }
        bundlePathCache = bundlePathCache.filter { seen.contains($0.key) }
        return result
    }

    /// Safari plays media from WebKit's shared GPU process.
    private static let sharedAudioHosts: [(prefix: String, host: String)] = [
        ("com.apple.WebKit", "com.apple.Safari"),
    ]

    private func bundlePath(for pid: pid_t) -> String? {
        if let cached = bundlePathCache[pid] { return cached }
        let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path
        bundlePathCache[pid] = .some(path)
        return path
    }

    private static func layOutSoundstage(_ apps: inout [AudioApp]) {
        let total = max(apps.count, 1)
        for i in apps.indices where !apps[i].isSpatialEnabled {
            let angle = Double(i) / Double(total) * 2 * .pi - .pi / 2
            apps[i].canvasX = 0.5 + 0.3 * cos(angle)
            apps[i].canvasY = 0.5 + 0.3 * sin(angle)
        }
    }

    // MARK: - Routing

    /// Brings the live route for an app in line with its current settings.
    private func applyRouting(_ pid: pid_t) {
        guard let i = index(of: pid) else { return }
        let app = apps[i]
        guard app.hasAudio else {
            // The app hasn't opened audio yet; route it as soon as it does.
            router.stopRoute(pid)
            pendingRoutes.insert(pid)
            return
        }
        guard let outputUID = app.outputDeviceUID ?? AudioDeviceManager.shared.defaultOutputDeviceUID() else { return }

        if router.matches(pid, processObjects: app.audioProcessObjects, outputUID: outputUID) {
            router.setMix(app.mix, for: pid)
            return
        }
        pendingRoutes.remove(pid)
        let result = router.startRoute(pid: pid, appName: app.name, processObjects: app.audioProcessObjects,
                                       outputUID: outputUID, mix: app.mix)
        if case .failure(let error) = result {
            showNotice("Couldn't take control of \(app.name)'s audio — \(error.description).")
        }
    }

    /// Rebuilds every live route, e.g. after the user grants audio access.
    func retryRouting() {
        hasHeardRoutedAudio = false
        silentPolls = 0
        audioAccessLikelyDenied = false
        for app in apps where router.isRouting(app.id) {
            router.stopRoute(app.id)
            applyRouting(app.id)
        }
    }

    /// Recording can end without the user (e.g. the output device's sample
    /// rate changed mid-recording); keep the model honest.
    private func syncRecordingState() {
        for i in apps.indices where apps[i].isRecording && !router.isRecording(apps[i].id) {
            apps[i].isRecording = false
            showNotice("Recording of \(apps[i].name) stopped because its audio route changed.")
        }
    }

    private func updateAudioAccessHeuristic() {
        guard !hasHeardRoutedAudio else { return }
        let routedPlaying = apps.filter { $0.isPlaying && router.isRouting($0.id) }
        if routedPlaying.contains(where: { router.sourceLevel(for: $0.id) > 0.0001 }) {
            hasHeardRoutedAudio = true
            audioAccessLikelyDenied = false
            return
        }
        silentPolls = routedPlaying.isEmpty ? 0 : silentPolls + 1
        if silentPolls >= 4, !audioAccessLikelyDenied {
            log.notice("Routed apps are playing but only silence is arriving")
            audioAccessLikelyDenied = true
        }
    }

    // MARK: - Mutators

    private func index(of pid: pid_t) -> Int? { apps.firstIndex { $0.id == pid } }

    private func update(_ app: AudioApp, route: Bool = true, _ change: (inout AudioApp) -> Void) {
        guard let i = index(of: app.id) else { return }
        change(&apps[i])
        if route { applyRouting(app.id) }
    }

    func setVolume(for app: AudioApp, to volume: Double) {
        update(app) {
            $0.volume = max(0, min(1, volume))
            $0.canvasY = 1 - $0.volume
        }
    }

    func setStereoPosition(for app: AudioApp, to position: Double) {
        update(app) {
            $0.stereoPosition = max(-1, min(1, position))
            $0.canvasX = $0.stereoPosition / 2 + 0.5
        }
    }

    func toggleMute(for app: AudioApp) {
        update(app) { $0.isMuted.toggle() }
    }

    /// `uid == nil` means "follow the system default output".
    func setOutputDevice(for app: AudioApp, uid: String?) {
        guard uid != app.outputDeviceUID else { return }
        update(app) { $0.outputDeviceUID = uid }
    }

    func setCanvasPosition(for app: AudioApp, x: Double, y: Double) {
        update(app, route: app.isSpatialEnabled) {
            $0.canvasX = x
            $0.canvasY = y
            if $0.isSpatialEnabled {
                $0.volume = max(0, min(1, 1 - y))
                $0.stereoPosition = (x - 0.5) * 2
            }
        }
    }

    func toggleSpatial(for app: AudioApp) {
        update(app, route: !app.isSpatialEnabled) {
            $0.isSpatialEnabled.toggle()
            if $0.isSpatialEnabled {
                $0.volume = max(0, min(1, 1 - $0.canvasY))
                $0.stereoPosition = ($0.canvasX - 0.5) * 2
            }
        }
    }

    func toggleRecording(for app: AudioApp) {
        guard let i = index(of: app.id) else { return }
        if apps[i].isRecording {
            let url = router.stopRecording(app.id)
            apps[i].isRecording = false
            if let url { showNotice("Saved “\(url.lastPathComponent)”", reveal: url) }
            return
        }
        applyRouting(app.id)
        guard router.isRouting(app.id) else {
            showNotice("\(app.name) hasn't played any audio yet — start playback, then record.")
            return
        }
        do {
            let url = try RecordingLocation.audio.newFileURL(named: "\(app.name) \(RecordingLocation.timestamp())", extension: "wav")
            try router.startRecording(app.id, to: url)
            apps[i].isRecording = true
        } catch {
            showNotice("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    /// Returns one app to untouched: settings reset and its audio handed back
    /// to macOS (no tap, no added processing).
    func resetChannel(for app: AudioApp) {
        guard let i = index(of: app.id) else { return }
        if apps[i].isRecording { toggleRecording(for: apps[i]) }
        apps[i].volume = 1
        apps[i].stereoPosition = 0
        apps[i].isMuted = false
        apps[i].outputDeviceUID = nil
        apps[i].isSpatialEnabled = false
        router.stopRoute(app.id)
        pendingRoutes.remove(app.id)
    }

    func resetAll() {
        for app in apps { resetChannel(for: app) }
        router.stopAll()
        Self.layOutSoundstage(&apps)
    }

    // MARK: - Notices

    func showNotice(_ text: String, reveal: URL? = nil) {
        notice = Notice(text: text, revealURL: reveal)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(reveal == nil ? 5 : 8))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
