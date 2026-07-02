import SwiftUI
import AppKit

@main
struct AudioMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup("Aura", id: "spatial-studio") {
            MainWindowView()
                .frame(minWidth: 600, minHeight: 450)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var dropdownWindow: NSPanel?
    private var appState = AppState.shared
    private var eventMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupDropdownWindow()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else { return }
        
        if let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "AudioMixer") {
            image.isTemplate = true
            button.image = image
        }
        
        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
    }
    
    private func setupDropdownWindow() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        
        // Native macOS 27 VisualEffectView for Menu Bar Dropdowns
        let effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        // Keep corners rounded
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 16
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        
        let contentView = NSHostingView(rootView: MenuBarDropdownView())
        contentView.frame = effectView.bounds
        contentView.autoresizingMask = [.width, .height]
        
        effectView.addSubview(contentView)
        window.contentView = effectView
        
        self.dropdownWindow = window
    }
    
    @objc private func statusBarButtonClicked(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let window = dropdownWindow else { return }
        
        if window.isVisible {
            closeDropdown()
        } else {
            let buttonFrame = button.window?.convertToScreen(button.frame) ?? .zero
            let windowFrame = window.frame
            
            let xPos = buttonFrame.origin.x + (buttonFrame.size.width / 2) - (windowFrame.size.width / 2)
            let yPos = buttonFrame.origin.y - windowFrame.size.height - 4
            
            window.setFrameOrigin(NSPoint(x: xPos, y: yPos))
            
            window.alphaValue = 0.0
            window.orderFront(nil)
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1.0
            }
            
            window.makeKey()
            
            // Monitor clicks outside the window to close it (native popover behavior)
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.closeDropdown()
            }
        }
    }
    
    private func closeDropdown() {
        guard let window = dropdownWindow, window.isVisible else { return }
        
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 0.0
        } completionHandler: {
            window.orderOut(nil)
        }
    }
    
    func applicationDidResignActive(_ notification: Notification) {
        closeDropdown()
    }
}
