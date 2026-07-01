import SwiftUI

// MARK: - Glass Volume Slider

struct GlassVolumeSlider: View {
    let app: AudioApp
    @ObservedObject var state = AppState.shared
    @State private var isDragging = false
    @State private var isHovering = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(isHovering ? 0.15 : 0.07), lineWidth: 0.5)
                    )
                
                // dB meter glow (activity indicator)
                if !app.isMuted && app.dbLevel > -50 {
                    let lvl = CGFloat(max(0, (app.dbLevel + 60) / 60.0))
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(app.accentColor.opacity(0.18))
                        .frame(width: geo.size.width * lvl)
                        .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.7), value: lvl)
                }
                
                // Volume fill
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [app.accentColor.opacity(app.isMuted ? 0.25 : 0.85),
                                 app.accentColor.opacity(app.isMuted ? 0.1 : 0.45)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: geo.size.width * CGFloat(app.volume))
                    .shadow(color: app.accentColor.opacity(app.isMuted ? 0 : 0.3), radius: 5, x: 1, y: 0)
                
                // Specular glass shine
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LinearGradient(
                        colors: [.white.opacity(0.25), .clear, .black.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 0.8)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    isDragging = true
                    let v = max(0, min(1, Double(g.location.x / geo.size.width)))
                    state.setVolume(for: app, to: v)
                }
                .onEnded { _ in withAnimation(.spring(response: 0.3)) { isDragging = false } }
            )
            .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
        }
        .frame(height: 22)
        .scaleEffect(y: isDragging ? 1.18 : (isHovering ? 1.08 : 1.0))
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isDragging || isHovering)
    }
}

// MARK: - Menu Bar Dropdown

public struct MenuBarDropdownView: View {
    @ObservedObject var state = AppState.shared
    @Environment(\.openWindow) private var openWindow
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 10) {
            
            // MARK: Header
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                
                Text("Audio Mixer")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                
                Spacer()
                
                // Global output device indicator
                if let dev = state.defaultDevice {
                    HStack(spacing: 4) {
                        Image(systemName: outputIcon(dev.name))
                            .font(.system(size: 9))
                        Text(dev.shortName)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(Capsule())
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: 120)
                }
                
                // Reset button
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        state.resetToDefaults()
                    }
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Reset all to defaults")
            }
            .padding(.horizontal, 4)
            
            Divider().opacity(0.4)
            
            // MARK: Show All Toggle (compact)
            if !state.showAllApps && state.visibleApps.isEmpty {
                Button(action: { state.showAllApps = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "eye")
                            .font(.system(size: 10))
                        Text("No active audio detected — tap to show all apps")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }
            
            // MARK: App List
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    let displayApps = state.showAllApps ? state.apps : state.visibleApps
                    ForEach(displayApps) { app in
                        appRow(for: app)
                    }
                    
                    // Show all toggle at bottom of list if hidden apps exist
                    if !state.showAllApps && state.apps.count > state.visibleApps.count {
                        Button(action: { state.showAllApps.toggle() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9))
                                Text("\(state.apps.count - state.visibleApps.count) more apps hidden")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    } else if state.showAllApps && state.apps.count > state.visibleApps.count {
                        Button(action: { state.showAllApps = false }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 9))
                                Text("Show active only")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 300)
            
            Divider().opacity(0.4)
            
            // MARK: Bottom Bar
            VStack(spacing: 8) {
                // System loopback toggle
                Toggle(isOn: $state.isLoopbackEnabled) {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 11))
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
                .padding(.horizontal, 2)
                
                HStack {
                    Button(action: {
                        openWindow(id: "spatial-studio")
                        NSApp.activate(ignoringOtherApps: true)
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
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Button(action: { NSApplication.shared.terminate(nil) }) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.red.opacity(0.8))
                            .padding(6)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Quit Audio Mixer")
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LinearGradient(
                    colors: [.white.opacity(0.45), .white.opacity(0.08), .clear, .black.opacity(0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 0.8)
        )
    }
    
    // MARK: - App Row
    
    @ViewBuilder
    private func appRow(for app: AudioApp) -> some View {
        HStack(spacing: 10) {
            // App icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(app.accentColor.opacity(0.1))
                    .frame(width: 32, height: 32)
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(app.accentColor)
                }
                
                // Active audio dot
                if app.dbLevel > -45 && !app.isMuted {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .offset(x: 12, y: -12)
                }
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // Per-app output device picker
                    Menu {
                        ForEach(state.devices) { device in
                            Button(action: { state.setOutputDevice(for: app, to: device) }) {
                                HStack {
                                    Text(device.name)
                                    if app.outputDevice.id == device.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: outputIcon(app.outputDevice.name))
                                .font(.system(size: 8))
                            Text(app.outputDevice.shortName)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 7))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 90)
                    }
                    .buttonStyle(.plain)
                }
                
                HStack(spacing: 6) {
                    GlassVolumeSlider(app: app)
                    
                    Text("\(Int(app.volume * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    
                    Button(action: { state.toggleMute(for: app) }) {
                        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(app.isMuted ? 0.1 : 0.04))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { state.toggleRecording(for: app) }) {
                        Image(systemName: app.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(app.isRecording ? Color.red : Color.secondary)
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(app.isRecording ? 0.1 : 0.04))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 2)
    }
    
    // MARK: - Helpers
    
    private func outputIcon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpod") || n.contains("headphone") { return "airpodspro" }
        if n.contains("speaker") { return "hifispeaker.fill" }
        if n.contains("hdmi") || n.contains("display") { return "display" }
        return "speaker.wave.2.fill"
    }
}

#Preview { MenuBarDropdownView() }
