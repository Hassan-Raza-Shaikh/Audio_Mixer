#if DEBUG
import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import SwiftUI
import os

/// Debug-only harness for exercising the audio paths without the UI.
/// Compiled out of Release (and therefore App Store) builds.
///
///   Aura -AuraSelfTestRoutePID <pid> [-AuraSelfTestVolume 0.5] [-AuraSelfTestSeconds 6] [-AuraSelfTestRecord YES]
///   Aura -AuraSelfTestScreenSeconds <n> [-AuraSelfTestScreenAudio NO]
///
/// Results go to the unified log (subsystem com.hassan.Aura, category selftest)
/// and stderr; the app quits when done.
@MainActor
enum SelfTest {
    private static let log = Logger(subsystem: "com.hassan.Aura", category: "selftest")
    private static let defaults = UserDefaults.standard

    static var isRequested: Bool {
        ["AuraSelfTestRoutePID", "AuraSelfTestScreenSeconds", "AuraSelfTestEnvironment", "AuraSelfTestSnapshotDir",
         "AuraSelfTestIdleSeconds", "AuraSelfTestProbeSeconds", "AuraSelfTestRecordThenRoutePID"]
            .contains { defaults.object(forKey: $0) != nil }
    }

    static func runIfRequested() {
        if defaults.object(forKey: "AuraSelfTestRoutePID") != nil {
            Task { await routeTest(pid: pid_t(defaults.integer(forKey: "AuraSelfTestRoutePID"))) }
        } else if defaults.object(forKey: "AuraSelfTestScreenSeconds") != nil {
            Task { await screenTest(seconds: defaults.double(forKey: "AuraSelfTestScreenSeconds")) }
        } else if defaults.bool(forKey: "AuraSelfTestEnvironment") {
            Task { await environmentTest() }
        } else if let dir = defaults.string(forKey: "AuraSelfTestSnapshotDir") {
            Task { await snapshotTest(into: URL(fileURLWithPath: dir, isDirectory: true)) }
        } else if defaults.object(forKey: "AuraSelfTestRecordThenRoutePID") != nil {
            Task { await recordThenRouteTest(pid: pid_t(defaults.integer(forKey: "AuraSelfTestRecordThenRoutePID"))) }
        } else if defaults.object(forKey: "AuraSelfTestProbeSeconds") != nil {
            Task { await probeTest(seconds: defaults.double(forKey: "AuraSelfTestProbeSeconds")) }
        } else if defaults.object(forKey: "AuraSelfTestIdleSeconds") != nil {
            Task {
                try? await Task.sleep(for: .seconds(2))     // let launch settle
                await measureCPU(for: defaults.double(forKey: "AuraSelfTestIdleSeconds"), label: "idle")
                finish(0)
            }
        }
    }

    // MARK: - Offscreen UI snapshots

    /// Renders the app's main surfaces in offscreen windows and saves PNGs,
    /// so the UI can be checked without touching the real screen.
    private static func snapshotTest(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppState.shared.refreshApps()
        try? await Task.sleep(for: .milliseconds(300))

        func snapshot<V: View>(_ view: V, size: CGSize, name: String) async {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(400))      // let SwiftUI settle
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            if fitting.height > 10, fitting.height != size.height {
                host.frame.size = CGSize(width: size.width, height: min(fitting.height, 1400))
                window.setContentSize(host.frame.size)
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { report("snapshot \(name) failed"); return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = dir.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            report("snapshot \(name) \(Int(host.bounds.width))x\(Int(host.bounds.height)) → \(url.path)")
        }

        await snapshot(MenuBarDropdownView(), size: CGSize(width: 360, height: 600), name: "menubar")
        await snapshot(MainWindowView(), size: CGSize(width: 860, height: 580), name: "main")
        await snapshot(SettingsView(), size: CGSize(width: 460, height: 520), name: "settings")
        finish(0)
    }

    // MARK: - Route an app partway through a screen recording

    /// Starts a screen recording, routes `pid` at 25% after 2 s, un-routes it
    /// 2.5 s later, and reports the recording's 440 Hz level per 0.5 s.
    /// Correct: 0.050 → 0.0125 → 0.050. If the recording tap didn't track the
    /// route change, the original and Aura's copy would mix (≥ 0.0375).
    private static func recordThenRouteTest(pid: pid_t) async {
        let recorder = ScreenRecorder.shared
        setRecordingAudio(true)
        await recorder.start()
        guard recorder.isRecording else { report("SCREEN START FAILED"); finish(4) }
        try? await Task.sleep(for: .seconds(2))

        let objects = AudioHAL.audioProcesses().filter { $0.pid == pid }.map(\.objectID)
        guard !objects.isEmpty, let outputUID = AudioDeviceManager.shared.defaultOutputDeviceUID() else { finish(2) }
        if case .failure(let error) = AudioRouter.shared.startRoute(pid: pid, appName: "selftest", processObjects: objects,
                                                                    outputUID: outputUID, mix: .init(volume: 0.25, pan: 0, muted: false)) {
            report("ROUTE FAILED: \(error.description)"); finish(3)
        }
        report("routed at 25% at t≈2s")
        try? await Task.sleep(for: .seconds(2.5))
        AudioRouter.shared.stopRoute(pid)
        report("unrouted at t≈4.5s")
        try? await Task.sleep(for: .seconds(2))

        await recorder.stopAndSave()
        guard let url = recorder.lastOutputURL else { report("SCREEN SAVE FAILED"); finish(5) }
        await analyzeMovie(url)
        finish(0)
    }

    // MARK: - System mix probe

    /// Listens to everything every other process is playing (no muting, no
    /// output) and reports the level — i.e. what actually reaches the speakers.
    private static func probeTest(seconds: Double) async {
        let own = AudioHAL.audioProcesses().filter { $0.pid == getpid() }.map(\.objectID)
        let probe = SystemAudioCapture(excluding: own) { _ in }
        do { try probe.start() } catch { report("PROBE FAILED: \(error)"); finish(3) }
        var windows: [Float] = []
        for _ in 0..<Int(seconds * 2) {
            var peak: Float = 0
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(50))
                peak = max(peak, probe.currentPeak)
            }
            windows.append(peak)
        }
        probe.stop()
        report("system mix per-0.5s: " + windows.map { String(format: "%.3f", $0) }.joined(separator: " "))
        let counts = probe.debugCounts.withLock { $0 }
        report("IO callbacks=\(counts.cycles) empty input=\(counts.empty) no host time=\(counts.noHostTime)")
        finish(0)
    }

    // MARK: - Environment test (sandbox capabilities)

    private static func environmentTest() async {
        report("sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")

        // 1. App ↔ audio-process attribution (helpers resolved to their app).
        let state = AppState.shared
        state.refreshApps()
        for app in state.apps where app.hasAudio {
            report("app \(app.name): \(app.audioProcessObjects.count) audio process(es) playing=\(app.isPlaying)")
        }

        // 2. Devices, and re-applying the current default output (a no-op
        //    that proves the sandbox allows changing it).
        report("devices: " + state.devices.map { "\($0.name)\($0.isDefault ? "*" : "")" }.joined(separator: ", "))
        if let current = state.defaultDevice {
            report("set default output allowed=\(AudioDeviceManager.shared.setDefaultOutputDevice(uid: current.id))")
        }

        // 3. Default recording folders resolve to the real ~/Movies and ~/Music.
        for directory in [FileManager.SearchPathDirectory.moviesDirectory, .musicDirectory] {
            let url = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
            let type = (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)?.rawValue ?? "missing"
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "-"
            report("\(url.lastPathComponent): \(url.path) type=\(type) → \(target)")
        }
        for (label, location) in [("screen", RecordingLocation.screen), ("audio", RecordingLocation.audio)] {
            let folder = location.url
            let existed = FileManager.default.fileExists(atPath: folder.path)
            do {
                let probe = try location.newFileURL(named: ".aura-write-test", extension: "tmp")
                try Data("ok".utf8).write(to: probe)
                try FileManager.default.removeItem(at: probe)
                if !existed { try? FileManager.default.removeItem(at: folder) }
                report("\(label) folder writable: \(location.displayPath)")
            } catch {
                report("\(label) folder NOT writable (\(location.displayPath)): \(error.localizedDescription)")
            }
        }
        finish(0)
    }

    private static func report(_ message: String) {
        log.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("SELFTEST \(message)\n".utf8))
    }

    private static func finish(_ code: Int32) -> Never {
        AudioRouter.shared.stopAll()
        // Put back the user's "include system audio" preference (tests change it).
        if let saved = savedIncludeAudio { ScreenRecorder.shared.includeAudio = saved }
        report("DONE code=\(code)")
        exit(code)
    }

    private static var savedIncludeAudio: Bool?

    /// Changes the recorder's audio setting for a test; `finish` restores it.
    private static func setRecordingAudio(_ enabled: Bool) {
        if savedIncludeAudio == nil { savedIncludeAudio = ScreenRecorder.shared.includeAudio }
        ScreenRecorder.shared.includeAudio = enabled
    }

    /// CPU time (user + system) this process has used, in seconds.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Measures average CPU over a window of wall-clock time.
    private static func measureCPU(for seconds: Double, label: String) async {
        let startCPU = cpuSeconds(), startWall = Date()
        try? await Task.sleep(for: .seconds(seconds))
        let wall = Date().timeIntervalSince(startWall)
        report(String(format: "CPU %@: %.2f%% of one core over %.1fs", label, (cpuSeconds() - startCPU) / wall * 100, wall))
    }

    // MARK: - Route test

    private static func routeTest(pid: pid_t) async {
        let seconds = defaults.object(forKey: "AuraSelfTestSeconds") != nil ? defaults.double(forKey: "AuraSelfTestSeconds") : 6
        let volume = defaults.object(forKey: "AuraSelfTestVolume") != nil ? Float(defaults.double(forKey: "AuraSelfTestVolume")) : 1
        report("sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")

        // Wait for the target to register with Core Audio.
        var objects: [AudioObjectID] = []
        for _ in 0..<20 {
            objects = AudioHAL.audioProcesses().filter { $0.pid == pid }.map(\.objectID)
            if !objects.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        report("pid=\(pid) processObjects=\(objects)")
        guard !objects.isEmpty, let outputUID = AudioDeviceManager.shared.defaultOutputDeviceUID() else { finish(2) }

        let router = AudioRouter.shared
        let result = router.startRoute(pid: pid, appName: "selftest-\(pid)", processObjects: objects,
                                       outputUID: outputUID, mix: .init(volume: volume, pan: 0, muted: false))
        if case .failure(let error) = result {
            report("ROUTE FAILED: \(error.description)")
            finish(3)
        }
        report("route started → \(outputUID) volume=\(volume)")

        var recordURL: URL?
        if defaults.bool(forKey: "AuraSelfTestRecord") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("aura-selftest-\(pid).wav")
            try? FileManager.default.removeItem(at: url)
            do {
                try router.startRecording(pid, to: url)
                recordURL = url
            } catch {
                report("record start failed: \(error.localizedDescription)")
            }
        }

        // Optionally record the screen from this same process while routing —
        // the real-world case (one Aura process does both).
        if defaults.object(forKey: "AuraSelfTestAlsoRecordScreen") != nil {
            let recordSeconds = defaults.double(forKey: "AuraSelfTestAlsoRecordScreen")
            let recorder = ScreenRecorder.shared
            setRecordingAudio(true)
            await recorder.start()
            try? await Task.sleep(for: .seconds(recordSeconds))
            await recorder.stopAndSave()
            if let url = recorder.lastOutputURL {
                report("same-process screen recording saved")
                await analyzeMovie(url)
            } else {
                report("same-process screen recording FAILED: \(AppState.shared.notice?.text ?? "unknown")")
            }
        }

        // Optionally listen to the whole system mix from this same process
        // (including its own routed output) — validates tap-based recording.
        var probe: SystemAudioCapture?
        if defaults.bool(forKey: "AuraSelfTestAlsoProbe") {
            // Optionally exclude the routed app itself (its pre-mute audio).
            let excluded = defaults.bool(forKey: "AuraSelfTestProbeExcludeRouted") ? objects : []
            let p = SystemAudioCapture(excluding: excluded) { _ in }
            do { try p.start(); probe = p } catch { report("probe failed: \(error)") }
        }
        var probeWindows: [Float] = []

        var maxSource: Float = 0, maxOutput: Float = 0
        let routeCPUStart = cpuSeconds(), routeWallStart = Date()
        let steps = Int(seconds * 4)
        for step in 0..<steps {
            try? await Task.sleep(for: .milliseconds(250))
            let source = router.sourceLevel(for: pid), output = router.outputLevel(for: pid)
            maxSource = max(maxSource, source)
            maxOutput = max(maxOutput, output)
            if let probe { probeWindows.append(probe.currentPeak) }
            if step % 4 == 3 { report(String(format: "t=%.1fs source=%.4f output=%.4f", Double(step + 1) / 4, source, output)) }
        }
        report(String(format: "CPU while routing: %.2f%% of one core",
                      (cpuSeconds() - routeCPUStart) / Date().timeIntervalSince(routeWallStart) * 100))
        if let probe {
            probe.stop()
            report("same-process system mix: " + probeWindows.map { String(format: "%.3f", $0) }.joined(separator: " "))
        }
        if let recorded = router.stopRecording(pid) ?? recordURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: recorded.path)[.size] as? Int) ?? 0
            report("recorded \(recorded.path) bytes=\(size)")
        }
        report(String(format: "RESULT maxSource=%.4f maxOutput=%.4f ratio=%.3f", maxSource, maxOutput,
                      maxSource > 0 ? maxOutput / maxSource : 0))
        finish(maxSource > 0 ? 0 : 1)
    }

    // MARK: - Screen recording test

    private static func screenTest(seconds: Double) async {
        let recorder = ScreenRecorder.shared
        setRecordingAudio(defaults.object(forKey: "AuraSelfTestScreenAudio") as? Bool ?? true)
        report("sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil) folder=\(RecordingLocation.screen.url.path)")
        await recorder.start()
        guard recorder.isRecording else {
            report("SCREEN START FAILED: \(AppState.shared.notice?.text ?? "unknown")")
            finish(4)
        }
        try? await Task.sleep(for: .seconds(seconds))
        await recorder.stopAndSave()
        guard let url = recorder.lastOutputURL else {
            report("SCREEN SAVE FAILED: \(AppState.shared.notice?.text ?? "unknown")")
            finish(5)
        }
        report("saved \(url.path)")
        await analyzeMovie(url)
        finish(0)
    }

    /// Reports the movie's tracks and the audio track's peak level.
    private static func analyzeMovie(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), let tracks = try? await asset.load(.tracks) else {
            report("ANALYZE FAILED"); return
        }
        report(String(format: "movie duration=%.2fs tracks=%d", duration.seconds, tracks.count))
        for track in tracks {
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let fps = (try? await track.load(.nominalFrameRate)) ?? 0
            let range = (try? await track.load(.timeRange)) ?? .zero
            report(String(format: "  track %@ %dx%d fps=%.1f start=%.3fs duration=%.3fs",
                          track.mediaType.rawValue, Int(size.width), Int(size.height), fps,
                          range.start.seconds, range.duration.seconds))
        }
        guard let audio = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { report("  no audio track"); return }
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var peak: Float = 0
        var windows: [Float] = []           // peak per 0.5 s (48 kHz stereo interleaved)
        var windowPeak: Float = 0, windowCount = 0
        // Amplitude of just the 440 Hz test tone per 0.5 s (Goertzel on the left
        // channel), so other audio playing on the Mac doesn't skew the result.
        let coeff = 2 * cos(2 * Double.pi * 440 / 48_000)
        var s1 = 0.0, s2 = 0.0, toneN = 0
        var toneWindows: [Double] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                for i in 0..<(length / 4) {
                    let v = abs(floats[i])
                    peak = max(peak, v)
                    windowPeak = max(windowPeak, v)
                    windowCount += 1
                    if windowCount == 48_000 { windows.append(windowPeak); windowPeak = 0; windowCount = 0 }
                    if i % 2 == 0 {                                 // left channel
                        let s = Double(floats[i]) + coeff * s1 - s2
                        s2 = s1; s1 = s; toneN += 1
                        if toneN == 24_000 {
                            let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
                            toneWindows.append(2 * sqrt(max(0, power)) / Double(toneN))
                            s1 = 0; s2 = 0; toneN = 0
                        }
                    }
                }
            }
        }
        report(String(format: "  audio peak=%.4f", peak))
        report("  per-0.5s peaks: " + windows.map { String(format: "%.3f", $0) }.joined(separator: " "))
        report("  440Hz tone per-0.5s: " + toneWindows.map { String(format: "%.3f", $0) }.joined(separator: " "))
    }
}
#endif
