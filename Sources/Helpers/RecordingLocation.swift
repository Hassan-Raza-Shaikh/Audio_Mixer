import AppKit
import Foundation
import os

/// A folder recordings are saved into. A user-chosen folder is remembered with
/// a security-scoped bookmark so it stays writable across launches inside the
/// App Sandbox; otherwise a default under ~/Movies or ~/Music is used.
@MainActor
final class RecordingLocation: ObservableObject {
    static let screen = RecordingLocation(
        key: "ScreenRecordingFolderBookmark",
        defaultURL: RecordingLocation.userFolder(.moviesDirectory, "Movies").appendingPathComponent("Aura Screen Recordings", isDirectory: true))

    static let audio = RecordingLocation(
        key: "AudioRecordingFolderBookmark",
        defaultURL: RecordingLocation.userFolder(.musicDirectory, "Music").appendingPathComponent("Aura Recordings", isDirectory: true))

    /// Where recordings currently go.
    @Published private(set) var url: URL
    var isDefault: Bool { url == defaultURL }

    /// Path suitable for showing to the user (sandbox container symlinks resolved).
    var displayPath: String {
        let path = resolvedURL.path
        let home = Self.realHomeDirectory
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// `url` with symlinks resolved — inside the sandbox the container's
    /// Movies/Music folders are symlinks to the real ones. Resolves the
    /// deepest existing ancestor, since the folder itself may not exist yet.
    var resolvedURL: URL {
        var existing = url
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// The user's actual home folder. Inside the sandbox NSHomeDirectory()
    /// points at the app container instead.
    private static let realHomeDirectory: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()

    private let key: String
    private let defaultURL: URL
    private var scopedURL: URL?
    private let log = Logger(subsystem: "com.hassan.Aura", category: "files")

    private init(key: String, defaultURL: URL) {
        self.key = key
        self.defaultURL = defaultURL
        self.url = defaultURL
        #if DEBUG
        // Self-tests write to the (container's) temp folder instead of ~/Movies.
        if UserDefaults.standard.object(forKey: "AuraSelfTestScreenSeconds") != nil
            || UserDefaults.standard.object(forKey: "AuraSelfTestRoutePID") != nil {
            self.url = FileManager.default.temporaryDirectory.appendingPathComponent("AuraSelfTest", isDirectory: true)
            return
        }
        #endif
        restoreBookmark()
    }

    /// Asks the user for a folder and remembers it.
    func choose(message: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = resolvedURL
        NSApp.activate()
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            let data = try chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
            beginAccess(chosen)
        } catch {
            log.error("Couldn't bookmark \(chosen.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: key)
        endAccess()
        url = defaultURL
    }

    /// Ensures the folder exists and returns a unique file URL inside it.
    func newFileURL(named base: String, extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var candidate = url.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    // MARK: - Private

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                      relativeTo: nil, bookmarkDataIsStale: &stale) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if stale, let fresh = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        beginAccess(resolved)
    }

    private func beginAccess(_ folder: URL) {
        endAccess()
        if folder.startAccessingSecurityScopedResource() { scopedURL = folder }
        url = folder
    }

    private func endAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private static func userFolder(_ directory: FileManager.SearchPathDirectory, _ fallback: String) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback)
    }

    /// A timestamp suitable for file names, e.g. "2026-09-24 at 14.03.22".
    static func timestamp() -> String {
        let formatter = DateFormatter()
        // Fixed format: without POSIX locale, a 12-hour system setting turns
        // "HH" into "h" and appends "am"/"pm".
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
