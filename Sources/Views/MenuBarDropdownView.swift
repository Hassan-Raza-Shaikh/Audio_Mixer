import SwiftUI

// MARK: - GPU-driven EQ Bars (TimelineView + Canvas — zero state mutations)

struct EQBars: View {
    let accentColor: Color
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let barCount = 3
                let gap: CGFloat = 1.5
                let barW = (size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
                let freqs: [Double] = [2.1, 3.4, 1.7]
                let phases: [Double] = [0.0, 1.3, 2.5]

                for i in 0..<barCount {
                    let amplitude = sin(t * freqs[i] + phases[i]) * 0.35 + 0.65
                    let h = size.height * amplitude
                    let x = CGFloat(i) * (barW + gap)
                    let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(accentColor))
                }
            }
        }
        .opacity(isActive ? 1.0 : 0.2)
        .animation(.easeInOut(duration: 0.35), value: isActive)
    }
}

// MARK: - Glass Volume Slider

struct GlassVolumeSlider: View {
    let app: AudioApp
    @ObservedObject var state = AppState.shared
    @State private var isDragging = false
    @State private var isHovering = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(isHovering ? 0.15 : 0.07), lineWidth: 0.5)
                    )

                // Mesh Gradient Volume fill
                if !app.isMuted {
                    MeshGradient(
                        width: 3, height: 3,
                        points: [
                            [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                            [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                            [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                        ],
                        colors: [
                            app.accentColor.opacity(0.8), app.accentColor.opacity(0.5), app.accentColor.opacity(0.8),
                            app.accentColor.opacity(0.5), app.accentColor, app.accentColor.opacity(0.5),
                            app.accentColor.opacity(0.8), app.accentColor.opacity(0.5), app.accentColor.opacity(0.8)
                        ]
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(width: geo.size.width * CGFloat(app.volume))
                    .shadow(color: app.accentColor.opacity(0.25), radius: 4, x: 1, y: 0)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: geo.size.width * CGFloat(app.volume))
                }

                // Glass shine
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LinearGradient(
                        colors: [.white.opacity(0.3), .clear, .white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    isDragging = true
                    state.setVolume(for: app, to: max(0, min(1, Double(g.location.x / geo.size.width))))
                }
                .onEnded { _ in withAnimation(.bouncy(duration: 0.4, extraBounce: 0.1)) { isDragging = false } }
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
            }
        }
        .frame(height: 22)
        .scaleEffect(y: isDragging ? 1.15 : (isHovering ? 1.06 : 1.0))
        .animation(.bouncy(duration: 0.3, extraBounce: 0.2), value: isDragging || isHovering)
    }
}

// MARK: - Menu Bar Dropdown

public struct MenuBarDropdownView: View {
    @ObservedObject var state = AppState.shared
    @Environment(\.openWindow) private var openWindow
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 10) {
            
            // Header
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Audio Mixer")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                
                Spacer()
                
                if let dev = state.defaultDevice {
                    HStack(spacing: 3) {
                        Image(systemName: outputIcon(dev.name)).font(.system(size: 9))
                        Text(dev.shortName).font(.system(size: 9, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(Capsule())
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: 110)
                }
                
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { state.resetToDefaults() }
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .glassEffect(.regular, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Reset all to defaults")
            }
            .padding(.horizontal, 2)
            
            Divider().opacity(0.4)
            
            // Toggle bar
            HStack {
                Toggle(isOn: $state.showAllApps) {
                    Text(state.showAllApps ? "All Apps" : "Audio Apps Only")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 4)
            
            // App list
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    let displayApps = state.showAllApps ? state.apps : state.visibleApps
                    ForEach(displayApps) { app in
                        appRow(app)
                            .scrollTransition(.animated.threshold(.visible(0.9))) { content, phase in
                                content
                                    .opacity(phase.isIdentity ? 1 : 0.4)
                                    .scaleEffect(phase.isIdentity ? 1 : 0.95)
                                    .blur(radius: phase.isIdentity ? 0 : 2)
                            }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
            
            Divider().opacity(0.4)
            
            // Bottom controls
            VStack(spacing: 8) {
                Toggle(isOn: $state.isLoopbackEnabled) {
                    HStack(spacing: 5) {
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
                            Image(systemName: "sparkles").font(.system(size: 10))
                            Text("Spatial Soundstage...").font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassEffect(.regular.tint(Color.accentColor.opacity(0.12)), in: .rect(cornerRadius: 8))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Button(action: { NSApplication.shared.terminate(nil) }) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.red.opacity(0.8))
                            .padding(5)
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
        // Removed custom ultraThinMaterial background to allow the NSVisualEffectView popover to render correctly.
        .background(Color.clear)
    }
    
    // MARK: - App Row
    
    @ViewBuilder
    private func appRow(_ app: AudioApp) -> some View {
        HStack(spacing: 10) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(app.accentColor.opacity(0.1))
                    .frame(width: 32, height: 32)
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22)
                } else {
                    Image(systemName: "app.fill").font(.system(size: 14)).foregroundStyle(app.accentColor)
                }
                // EQ bars replace the static activity dot
                EQBars(accentColor: app.accentColor, isActive: app.isKnownAudioApp && !app.isMuted)
                    .frame(width: 14, height: 9)
                    .offset(x: 9, y: 11)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Spacer()
                    
                    // Device picker
                    Menu {
                        ForEach(state.devices) { device in
                            Button(action: { 
                                withAnimation(.bouncy) { state.setOutputDevice(for: app, to: device) }
                            }) {
                                HStack {
                                    Text(device.name)
                                    if app.outputDevice.id == device.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: outputIcon(app.outputDevice.name)).font(.system(size: 8))
                            Text(app.outputDevice.shortName).font(.system(size: 9, weight: .medium)).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2)
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
                    
                    Button(action: { 
                        withAnimation(.bouncy(duration: 0.4)) { state.toggleMute(for: app) }
                    }) {
                        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(app.isMuted ? 0.1 : 0.04))
                            .clipShape(Circle())
                            .scaleEffect(app.isMuted ? 0.9 : 1.0)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { 
                        withAnimation(.bouncy(duration: 0.4)) { state.toggleRecording(for: app) }
                    }) {
                        Image(systemName: app.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(app.isRecording ? Color.red : Color.secondary)
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(app.isRecording ? 0.1 : 0.04))
                            .clipShape(Circle())
                            .scaleEffect(app.isRecording ? 1.1 : 1.0)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private func outputIcon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpod") || n.contains("headphone") { return "airpodspro" }
        if n.contains("speaker") { return "hifispeaker.fill" }
        if n.contains("hdmi") || n.contains("display") { return "display" }
        return "speaker.wave.2.fill"
    }
}

#Preview { MenuBarDropdownView() }
