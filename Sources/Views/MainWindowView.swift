import SwiftUI

// MARK: - App Node View (Spatial Canvas)

struct AppNodeView: View {
    let app: AudioApp
    let canvasSize: CGSize
    @ObservedObject var state = AppState.shared
    
    @State private var isDragging = false
    
    var posX: CGFloat { CGFloat(app.canvasX) * canvasSize.width }
    var posY: CGFloat { CGFloat(app.canvasY) * canvasSize.height }
    
    var isActive: Bool { app.dbLevel > -45 }
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Pulse ring for active/audio-producing apps
                if isActive && !app.isMuted {
                    Circle()
                        .stroke(app.accentColor.opacity(0.3), lineWidth: 2)
                        .frame(width: 56, height: 56)
                        .scaleEffect(isDragging ? 1.3 : 1.1)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isActive)
                }
                
                // Glow
                Circle()
                    .fill(app.accentColor.opacity(isDragging ? 0.4 : 0.12))
                    .frame(width: 46, height: 46)
                    .blur(radius: isDragging ? 10 : 5)
                
                // Ring border
                Circle()
                    .stroke(app.accentColor.opacity(app.isMuted ? 0.2 : (isDragging ? 1.0 : 0.5)), lineWidth: 1.5)
                    .frame(width: 46, height: 46)
                
                // Real app icon
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                        .opacity(app.isMuted ? 0.4 : 1.0)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(app.accentColor)
                }
                
                // Muted overlay
                if app.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(3)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .offset(x: 14, y: -14)
                }
            }
            
            // App name label
            Text(app.name)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            
            // Output device badge
            Text(app.outputDevice.shortName)
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundStyle(app.accentColor.opacity(0.8))
                .lineLimit(1)
        }
        .scaleEffect(isDragging ? 1.15 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isDragging)
        .position(x: posX, y: posY)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    let nx = max(0.05, min(0.95, Double(value.location.x / canvasSize.width)))
                    let ny = max(0.05, min(0.95, Double(value.location.y / canvasSize.height)))
                    state.setCanvasPosition(for: app, x: nx, y: ny)
                    // Stereo position derived from X (left = -1, right = +1)
                    let stereo = (nx - 0.5) * 2.0
                    state.setStereoPosition(for: app, to: stereo)
                    // Volume derived from Y (top = loud, bottom = quiet)
                    let vol = 1.0 - ny
                    state.setVolume(for: app, to: max(0, min(1, vol)))
                }
                .onEnded { _ in isDragging = false }
        )
    }
}

// MARK: - Main Window View

public struct MainWindowView: View {
    @ObservedObject var state = AppState.shared
    @State private var selectedAppId: UUID? = nil
    
    public init() {}
    
    var selectedApp: AudioApp? {
        state.apps.first(where: { $0.id == selectedAppId })
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            
            // MARK: Spatial Canvas
            VStack(spacing: 0) {
                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spatial Soundstage")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("Drag apps to position stereo. Up = louder · Left/Right = stereo balance")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    // Show All toggle
                    Toggle(isOn: $state.showAllApps) {
                        Text("Show All")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .help("Show all running apps, not just audio-producing ones")
                    
                    // Reset Layout button
                    Button(action: {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                            state.resetToDefaults()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .font(.system(size: 13))
                            Text("Reset")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset all volumes, stereo positions, and layout to defaults")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                
                Divider().opacity(0.3)
                
                // Canvas
                GeometryReader { geo in
                    ZStack {
                        // Radial grid rings
                        ForEach([0.25, 0.5, 0.75], id: \.self) { frac in
                            Ellipse()
                                .stroke(Color.primary.opacity(0.05), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                                .frame(
                                    width: geo.size.width * frac,
                                    height: geo.size.height * frac
                                )
                        }
                        
                        // Axis cross lines
                        Path { p in
                            p.move(to: CGPoint(x: geo.size.width / 2, y: 20))
                            p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height - 20))
                            p.move(to: CGPoint(x: 20, y: geo.size.height / 2))
                            p.addLine(to: CGPoint(x: geo.size.width - 20, y: geo.size.height / 2))
                        }
                        .stroke(Color.primary.opacity(0.04), lineWidth: 1)
                        
                        // Axis labels
                        Group {
                            Text("LOUD").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary.opacity(0.5))
                                .position(x: geo.size.width / 2, y: 10)
                            Text("QUIET").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary.opacity(0.5))
                                .position(x: geo.size.width / 2, y: geo.size.height - 10)
                            Text("L").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary.opacity(0.5))
                                .position(x: 12, y: geo.size.height / 2)
                            Text("R").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary.opacity(0.5))
                                .position(x: geo.size.width - 12, y: geo.size.height / 2)
                        }
                        
                        // Center listener icon
                        VStack(spacing: 3) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.12))
                                    .frame(width: 40, height: 40)
                                Circle()
                                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                                    .frame(width: 40, height: 40)
                                Image(systemName: "headphones")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text("YOU")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.accentColor)
                        }
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        
                        // App nodes — filtered smartly
                        ForEach(state.showAllApps ? state.apps : state.visibleApps) { app in
                            AppNodeView(app: app, canvasSize: geo.size)
                                .onTapGesture { selectedAppId = app.id }
                        }
                        
                        // Empty state
                        if state.visibleApps.isEmpty && !state.showAllApps {
                            VStack(spacing: 8) {
                                Image(systemName: "waveform.slash")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.secondary)
                                Text("No active audio apps detected")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Button("Show All Apps") { state.showAllApps = true }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .frame(minWidth: 420, maxWidth: .infinity, minHeight: 450, maxHeight: .infinity)
            
            Divider().opacity(0.3)
            
            // MARK: Inspector Panel
            VStack(spacing: 0) {
                if let app = selectedApp {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            
                            // App header
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(app.accentColor.opacity(0.12))
                                        .frame(width: 44, height: 44)
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 30, height: 30)
                                    } else {
                                        Image(systemName: "app.fill")
                                            .foregroundStyle(app.accentColor)
                                            .font(.system(size: 20))
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                    Text("PID \(app.pid)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            
                            Divider().opacity(0.4)
                            
                            // Output device picker
                            VStack(alignment: .leading, spacing: 6) {
                                Label("OUTPUT DEVICE", systemImage: "speaker.wave.2")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                
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
                                    HStack {
                                        Image(systemName: deviceIcon(for: app.outputDevice.name))
                                            .font(.system(size: 11))
                                        Text(app.outputDevice.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                            
                            Divider().opacity(0.4)
                            
                            // Spatial controls
                            VStack(alignment: .leading, spacing: 10) {
                                Label("SPATIAL CONTROLS", systemImage: "scope")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                
                                // Volume
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Volume")
                                            .font(.system(size: 11, weight: .medium))
                                        Spacer()
                                        Text("\(Int(app.volume * 100))%")
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(app.accentColor)
                                    }
                                    Slider(value: Binding(
                                        get: { app.volume },
                                        set: { state.setVolume(for: app, to: $0) }
                                    ), in: 0...1)
                                    .tint(app.accentColor)
                                }
                                
                                // Stereo position
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Stereo Position")
                                            .font(.system(size: 11, weight: .medium))
                                        Spacer()
                                        Text(stereoLabel(app.stereoPosition))
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(app.accentColor)
                                    }
                                    Slider(value: Binding(
                                        get: { app.stereoPosition },
                                        set: { state.setStereoPosition(for: app, to: $0) }
                                    ), in: -1...1)
                                    .tint(app.accentColor)
                                    
                                    HStack {
                                        Text("L").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                                        Spacer()
                                        Text("Center").font(.system(size: 8)).foregroundStyle(.secondary)
                                        Spacer()
                                        Text("R").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            
                            Divider().opacity(0.4)
                            
                            // Quick actions
                            VStack(alignment: .leading, spacing: 6) {
                                Label("QUICK ACTIONS", systemImage: "bolt")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                
                                HStack(spacing: 8) {
                                    // Mute button
                                    Button(action: { state.toggleMute(for: app) }) {
                                        Label(app.isMuted ? "Unmute" : "Mute",
                                              systemImage: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 7)
                                            .background(app.isMuted ? Color.red.opacity(0.12) : Color.primary.opacity(0.06))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .foregroundStyle(app.isMuted ? .red : .primary)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    // Record button
                                    Button(action: { state.toggleRecording(for: app) }) {
                                        Label(app.isRecording ? "Stop" : "Record",
                                              systemImage: app.isRecording ? "stop.circle.fill" : "record.circle")
                                            .font(.system(size: 11, weight: .semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 7)
                                            .background(app.isRecording ? Color.red.opacity(0.12) : Color.primary.opacity(0.06))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .foregroundStyle(app.isRecording ? .red : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                // Snap to center
                                Button(action: {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                        state.snapToCenter(for: app)
                                    }
                                }) {
                                    Label("Snap to Center", systemImage: "scope")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(Color.primary.opacity(0.06))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Reset this app to center position with default volume")
                            }
                        }
                        .padding(16)
                    }
                } else {
                    // Empty state
                    VStack(spacing: 10) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("Select an App")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("Tap any node on the soundstage to inspect and control its audio settings.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 240)
            .background(.ultraThinMaterial)
        }
        .frame(width: 680, height: 480)
        .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
    }
    
    // MARK: - Helpers
    
    private func stereoLabel(_ pos: Double) -> String {
        if pos < -0.05 { return "L \(Int(abs(pos) * 100))%" }
        if pos > 0.05  { return "R \(Int(pos * 100))%" }
        return "Center"
    }
    
    private func deviceIcon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpod") || n.contains("headphone") || n.contains("ear") { return "airpodspro" }
        if n.contains("speaker") { return "hifispeaker.fill" }
        if n.contains("hdmi") || n.contains("display") { return "display" }
        return "speaker.wave.2.fill"
    }
}

// MARK: - NSVisualEffectView Wrapper

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

#Preview { MainWindowView() }
