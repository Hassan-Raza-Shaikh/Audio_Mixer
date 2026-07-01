import SwiftUI

/// A premium glassmorphic slider that represents both volume level and real-time audio levels
struct GlassVolumeSlider: View {
    let app: AudioApp
    @ObservedObject var state = AppState.shared
    
    @State private var isDragging = false
    @State private var isHovering = false
    
    var body: some View {
        VParallaxSlider(
            value: Binding(
                get: { app.volume },
                set: { state.setVolume(for: app, to: $0) }
            ),
            accentColor: app.accentColor,
            dbLevel: app.dbLevel,
            isMuted: app.isMuted,
            isDragging: $isDragging,
            isHovering: $isHovering
        )
    }
}

/// Custom interactive spring slider with audio meter visualizer overlay
struct VParallaxSlider: View {
    @Binding var value: Double
    let accentColor: Color
    let dbLevel: Float
    let isMuted: Bool
    @Binding var isDragging: Bool
    @Binding var isHovering: Bool
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background Track with Backdrop Blur
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .background(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(isHovering || isDragging ? 0.15 : 0.08), lineWidth: 0.5)
                    )
                
                // Real-time Decibel Audio Flow meter (underlay glow)
                if !isMuted {
                    let normalizedLevel = CGFloat(max(0, (dbLevel + 60) / 60.0)) // Map -60..0 to 0..1
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.15), accentColor.opacity(0.02)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * normalizedLevel)
                        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.65), value: normalizedLevel)
                }
                
                // Volume Level Filled Track
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(isMuted ? 0.3 : 0.8), accentColor.opacity(isMuted ? 0.15 : 0.5)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * CGFloat(value))
                    .shadow(color: accentColor.opacity(isMuted ? 0 : 0.25), radius: 6, x: 2, y: 0)
                
                // Specular Light Overlay for Glass Effect
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.3), .clear, .black.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let rawLocation = gesture.location.x
                        let relativeLocation = max(0, min(1, rawLocation / geometry.size.width))
                        value = Double(relativeLocation)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            isDragging = false
                        }
                    }
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.2)) {
                    isHovering = hovering
                }
            }
        }
        .frame(height: 24)
        .scaleEffect(y: isDragging ? 1.15 : (isHovering ? 1.08 : 1.0))
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isDragging || isHovering)
    }
}

public struct MenuBarDropdownView: View {
    @ObservedObject var state = AppState.shared
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 12) {
            // Header with App Title & Global Quick Controls
            HStack {
                Text("AudioMixer")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                // Quick global output indicator
                if let defDev = state.defaultDevice {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.bubble")
                            .font(.system(size: 10))
                        Text(defDev.name)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            
            Divider()
                .opacity(0.5)
            
            // App-specific mixers list
            VStack(spacing: 14) {
                ForEach(state.apps) { app in
                    HStack(spacing: 10) {
                        // App Icon (Placeholder using system images with active-color backgrounds)
                        ZStack {
                            Circle()
                                .fill(app.accentColor.opacity(0.12))
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: app.name == "Spotify" ? "music.note" :
                                    (app.name.contains("Zoom") ? "video.fill" :
                                    (app.name == "Safari" ? "safari.fill" : "app.badge")))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(app.accentColor)
                        }
                        
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(app.name)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                
                                Spacer()
                                
                                // Direct routing menu button
                                Menu {
                                    ForEach(state.devices) { device in
                                        Button(action: {
                                            state.setOutputDevice(for: app, to: device)
                                        }) {
                                            HStack {
                                                Text(device.name)
                                                if app.outputDevice.id == device.id {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(app.outputDevice.name.components(separatedBy: " ").first ?? "Output")
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 8))
                                    }
                                    .font(.system(size: 10, weight: .regular))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            
                            HStack(spacing: 8) {
                                // Glass Slider with Meter
                                GlassVolumeSlider(app: app)
                                
                                // Volume level percentage text
                                Text("\(Int(app.volume * 100))%")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                                
                                // Quick Actions: Mute & Record
                                Button(action: { state.toggleMute(for: app) }) {
                                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
                                        .frame(width: 18, height: 18)
                                        .background(Color.primary.opacity(app.isMuted ? 0.1 : 0.04))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { state.toggleRecording(for: app) }) {
                                    Image(systemName: "record.circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(app.isRecording ? Color.red : Color.secondary)
                                        .frame(width: 18, height: 18)
                                        .background(Color.primary.opacity(app.isRecording ? 0.1 : 0.04))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            
            Divider()
                .opacity(0.5)
                .padding(.top, 4)
            
            // Bottom Bar: System Loopback & Configuration toggles
            VStack(spacing: 8) {
                // Screen Recording loopback toggle
                Toggle(isOn: $state.isLoopbackEnabled) {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(state.isLoopbackEnabled ? .red : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("System Audio Loopback")
                                .font(.system(size: 11, weight: .medium))
                            Text("Pipes screen audio to screen recorders")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .red))
                .padding(.horizontal, 4)
                
                HStack {
                    // Open spatial soundstage window
                    Button(action: {
                        state.isAccessoryMode = false
                        // Open window logic
                        if let window = NSApplication.shared.windows.first(where: { $0.title == "AudioMixer Spatial Studio" }) {
                            window.makeKeyAndOrderFront(nil)
                        } else {
                            // Present spatial window
                            let spatialWindow = NSWindow(
                                contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
                                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
                            spatialWindow.title = "AudioMixer Spatial Studio"
                            spatialWindow.contentView = NSHostingView(rootView: MainWindowView())
                            spatialWindow.center()
                            spatialWindow.isReleasedWhenClosed = false
                            spatialWindow.makeKeyAndOrderFront(nil)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text("Spatial Soundstage...")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.accent)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    // Toggle App Mode (Dock/Menu bar)
                    Button(action: {
                        state.isAccessoryMode.toggle()
                    }) {
                        Image(systemName: state.isAccessoryMode ? "macpro.gen3.fill" : "sidebar.squares.leading")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .help(state.isAccessoryMode ? "Show in Dock" : "Hide in Dock")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    MenuBarDropdownView()
}
