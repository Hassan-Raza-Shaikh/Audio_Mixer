import SwiftUI
import AppKit

@main
struct AudioMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // We do not declare a WindowGroup here because we manage all windows manually.
        // This prevents macOS from launching an empty window when the application starts
        // and gives us total control over the accessory/menu-bar only launch behavior.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var dropdownWindow: NSWindow?
    private var appState = AppState.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set application activation policy based on preferences
        NSApp.setActivationPolicy(appState.isAccessoryMode ? .accessory : .regular)
        
        setupStatusItem()
        setupDropdownWindow()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else { return }
        
        // Use a high-quality native system icon representing sliders/knobs
        button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "AudioMixer")
        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
    }
    
    private func setupDropdownWindow() {
        // Create a custom borderless panel for the drop-down menu
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        
        // Host our SwiftUI MenuBarDropdownView
        let contentView = NSHostingView(rootView: MenuBarDropdownView())
        window.contentView = contentView
        
        self.dropdownWindow = window
    }
    
    @objc private func statusBarButtonClicked(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let window = dropdownWindow else { return }
        
        if window.isVisible {
            // Dismiss window with a fade-out animation
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 0.0
            } completionHandler: {
                window.orderOut(nil)
            }
        } else {
            // Position the window directly below the menu bar item
            let buttonFrame = button.window?.convertToScreen(button.frame) ?? .zero
            let windowFrame = window.frame
            
            let xPos = buttonFrame.origin.x + (buttonFrame.size.width / 2) - (windowFrame.size.width / 2)
            let yPos = buttonFrame.origin.y - windowFrame.size.height - 4 // 4pt gap
            
            window.setFrameOrigin(NSPoint(x: xPos, y: yPos))
            
            // Fade-in slide down animation
            window.alphaValue = 0.0
            window.orderFront(nil)
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1.0
            }
            
            // Make key to receive keyboard focus (allows using sliders and hotkeys)
            window.makeKey()
        }
    }
    
    func applicationDidResignActive(_ notification: Notification) {
        // Automatically hide the menu dropdown when the user clicks away
        if let window = dropdownWindow, window.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 0.0
            } completionHandler: {
                window.orderOut(nil)
            }
        }
    }
}
