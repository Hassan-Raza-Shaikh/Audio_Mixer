import CoreAudio
import Foundation
import os

/// Owns the live per-app audio routes, keyed by each app's main PID.
///
/// Apps that have never been touched aren't routed at all — their audio takes
/// the normal macOS path with zero overhead. A route is created the first time
/// the user changes something for that app, and removed again on reset.
final class AudioRouter: @unchecked Sendable {
    static let shared = AudioRouter()

    private let lock = NSLock()
    private var routes: [pid_t: AppAudioRoute] = [:]
    /// Recorders outlive route rebuilds (e.g. a browser spawning a new audio
    /// helper mid-recording) so one recording stays one file.
    private var recorders: [pid_t: AudioFileRecorder] = [:]
    private let log = Logger(subsystem: "com.hassan.Aura", category: "router")

    private init() {}

    private func route(_ pid: pid_t) -> AppAudioRoute? {
        lock.withLock { routes[pid] }
    }

    func isRouting(_ pid: pid_t) -> Bool { route(pid) != nil }

    /// What the user hears from this app (0 when not routed).
    func outputLevel(for pid: pid_t) -> Float { route(pid)?.currentLevels.output ?? 0 }

    /// The app's own signal before Aura's gain (0 when not routed).
    func sourceLevel(for pid: pid_t) -> Float { route(pid)?.currentLevels.source ?? 0 }

    func isRecording(_ pid: pid_t) -> Bool { lock.withLock { recorders[pid] != nil } }

    /// Audio processes of every routed app. Their original audio is muted at
    /// the hardware but still visible to taps, so recordings must exclude them.
    var routedProcessObjects: [AudioObjectID] {
        lock.withLock { routes.values.flatMap(\.processObjects) }
    }

    /// Called whenever the set of routed processes changes (e.g. so an ongoing
    /// screen recording can update what it excludes).
    var onRoutesChanged: (@Sendable () -> Void)? {
        get { lock.withLock { routesChangedHandler } }
        set { lock.withLock { routesChangedHandler = newValue } }
    }
    private var routesChangedHandler: (@Sendable () -> Void)?

    private func notifyRoutesChanged() {
        onRoutesChanged?()
    }

    /// Returns true if the existing route already matches these inputs.
    func matches(_ pid: pid_t, processObjects: [AudioObjectID], outputUID: String) -> Bool {
        guard let existing = route(pid) else { return false }
        return existing.processObjects == processObjects && existing.outputUID == outputUID
    }

    /// Creates (or rebuilds) the route for an app. Rebuilding stops any
    /// in-progress recording for that app.
    @discardableResult
    func startRoute(pid: pid_t, appName: String, processObjects: [AudioObjectID],
                    outputUID: String, mix: AppAudioRoute.Mix) -> Result<Void, AppAudioRoute.RouteError> {
        removeRoute(pid)
        let newRoute = AppAudioRoute(appName: appName, processObjects: processObjects, outputUID: outputUID, mix: mix)
        do {
            try newRoute.start()
        } catch let error as AppAudioRoute.RouteError {
            log.error("Route for \(appName, privacy: .public) failed: \(error.description, privacy: .public)")
            return .failure(error)
        } catch {
            return .failure(.startFailed(-1))
        }

        // Carry an in-progress recording over to the rebuilt route. A different
        // sample rate (new output device) can't continue the same file.
        let recorder = lock.withLock { recorders[pid] }
        if let recorder {
            if recorder.format.sampleRate == newRoute.sampleRate {
                newRoute.attach(recorder: recorder)
            } else {
                _ = finishRecording(pid)
            }
        }
        lock.withLock { routes[pid] = newRoute }
        log.info("Routing \(appName, privacy: .public) (\(processObjects.count) process(es)) → \(outputUID, privacy: .public)")
        notifyRoutesChanged()
        return .success(())
    }

    func setMix(_ mix: AppAudioRoute.Mix, for pid: pid_t) {
        route(pid)?.setMix(mix)
    }

    /// Stops routing an app (and any recording of it); its audio returns to normal.
    func stopRoute(_ pid: pid_t) {
        removeRoute(pid)
        _ = finishRecording(pid)
    }

    func stopAll() {
        let (allRoutes, allRecorders) = lock.withLock { () -> ([AppAudioRoute], [AudioFileRecorder]) in
            defer { routes.removeAll(); recorders.removeAll() }
            return (Array(routes.values), Array(recorders.values))
        }
        allRoutes.forEach { $0.stop() }
        allRecorders.forEach { $0.finish() }
        if !allRoutes.isEmpty { notifyRoutesChanged() }
    }

    /// Starts recording a routed app's audio to a WAV file.
    func startRecording(_ pid: pid_t, to url: URL) throws {
        guard let route = route(pid) else { throw CocoaError(.fileWriteUnknown) }
        let recorder = try AudioFileRecorder(url: url, sampleRate: route.sampleRate)
        lock.withLock { recorders[pid] = recorder }
        route.attach(recorder: recorder)
    }

    /// Stops recording and returns the finished file.
    func stopRecording(_ pid: pid_t) -> URL? {
        finishRecording(pid)
    }

    // MARK: - Private

    private func removeRoute(_ pid: pid_t) {
        let removed = lock.withLock { routes.removeValue(forKey: pid) }
        removed?.stop()
        if removed != nil { notifyRoutesChanged() }
    }

    private func finishRecording(_ pid: pid_t) -> URL? {
        guard let recorder = lock.withLock({ recorders.removeValue(forKey: pid) }) else { return nil }
        route(pid)?.attach(recorder: nil)
        recorder.finish()
        return recorder.url
    }
}
