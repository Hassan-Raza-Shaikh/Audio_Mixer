import SwiftUI
import AppKit

@main
struct AudioMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup("AudioMixer Spatial Studio", id: "spatial-studio") {
            MainWindowView()
                .frame(minWidth: 600, minHeight: 450)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var appState = AppState.shared
    private var eventMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the app running in the menu bar even when the main window is closed
        return false
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else { return }
        
        // Use a high-quality native system icon representing sliders/knobs
        button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "AudioMixer")
        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
    }
    
    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 400)
        popover.behavior = .transient // Automatically closes when clicking outside
        popover.contentViewController = NSHostingController(rootView: MenuBarDropdownView())
        popover.delegate = self
        self.popover = popover
    }
    
    @objc private func statusBarButtonClicked(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover = popover else { return }
        
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Position the popover directly below the menu bar item
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            // To ensure it appears over fullscreen apps, bring the app forward
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func popoverWillShow(_ notification: Notification) {
        // Additional setup if needed before showing
    }
    
    func popoverDidClose(_ notification: Notification) {
        // Handle cleanup if needed
    }
}
