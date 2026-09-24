import AppKit
import SwiftUI

@main
struct AuraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Aura", id: "mixer") {
            MainWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 580)
        // Opened explicitly by MenuBarLabel so a login-item launch stays quiet.
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarDropdownView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// The menu-bar icon. Shows a record symbol while a screen recording runs, and
/// opens the mixer window on a normal (non–login item) launch.
private struct MenuBarLabel: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: recorder.isRecording ? "record.circle" : "slider.horizontal.3")
            .accessibilityLabel(recorder.isRecording ? "Aura – recording" : "Aura")
            .task {
                guard !AppDelegate.launchedAsLoginItem, !AppDelegate.didOpenInitialWindow else { return }
                AppDelegate.didOpenInitialWindow = true
                openWindow(id: "mixer")
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launchedAsLoginItem = false
    static var didOpenInitialWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        Self.launchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        #if DEBUG
        if SelfTest.isRequested { Self.didOpenInitialWindow = true }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppState.shared     // start watching apps and devices right away
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // keep living in the menu bar
    }

    /// Don't lose an in-progress screen recording on quit: finish the file first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ScreenRecorder.shared.isRecording else { return .terminateNow }
        Task { @MainActor in
            await ScreenRecorder.shared.stopAndSave()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Hand every app's audio back to macOS and close any open recordings.
        AudioRouter.shared.stopAll()
    }
}
