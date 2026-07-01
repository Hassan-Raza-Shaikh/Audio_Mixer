import SwiftUI

// MARK: - App Node (Spatial Canvas)

struct AppNodeView: View {
    let app: AudioApp
    let canvasSize: CGSize
    let isSelected: Bool
    let onSelect: () -> Void
    @ObservedObject var state = AppState.shared
    
    @State private var isDragging = false
    @State private var dragStartPos: CGPoint = .zero
    
    var posX: CGFloat { CGFloat(app.canvasX) * canvasSize.width }
    var posY: CGFloat { CGFloat(app.canvasY) * canvasSize.height }
    var isActive: Bool { app.isKnownAudioApp && !app.isMuted }
    
    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                // Pulse ring for active audio apps
                if isActive {
                    Circle()
                        .stroke(app.accentColor.opacity(0.25), lineWidth: 2)
                        .frame(width: 54, height: 54)
                        .scaleEffect(1.08)
                }
                
                // Selection ring
                if isSelected {
                    Circle()
                        .stroke(Color.white.opacity(0.8), lineWidth: 2.5)
                        .frame(width: 52, height: 52)
                }
                
                // Glow
                Circle()
                    .fill(app.accentColor.opacity(isDragging ? 0.35 : 0.12))
                    .frame(width: 46, height: 46)
                    .blur(radius: isDragging ? 8 : 4)
                
                // Border ring
                Circle()
                    .stroke(app.accentColor.opacity(app.isMuted ? 0.2 : 0.5), lineWidth: 1.5)
                    .frame(width: 46, height: 46)
                
                // Real icon
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .opacity(app.isMuted ? 0.4 : 1.0)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(app.accentColor)
                }
                
                // Muted badge
                if app.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(2)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .offset(x: 14, y: -14)
                }
            }
            
            // Name label
            Text(app.name)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            
            // Output badge
            Text(app.outputDevice.shortName)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(app.accentColor.opacity(0.7))
                .lineLimit(1)
        }
        .scaleEffect(isDragging ? 1.15 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.65), value: isDragging)
        .position(x: posX, y: posY)
        .gesture(
            DragGesture(minimumDistance: 5)  // 5pt threshold so taps pass through
                .onChanged { value in
                    isDragging = true
                    let nx = max(0.05, min(0.95, Double(value.location.x / canvasSize.width)))
                    let ny = max(0.05, min(0.95, Double(value.location.y / canvasSize.height)))
                    state.setCanvasPosition(for: app, x: nx, y: ny)
                    state.setStereoPosition(for: app, to: (nx - 0.5) * 2.0)
                    state.setVolume(for: app, to: max(0, min(1, 1.0 - ny)))
                }
                .onEnded { _ in isDragging = false }
        )
        .onTapGesture {
            onSelect()
        }
    }
}

// MARK: - Main Window

public struct MainWindowView: View {
    @ObservedObject var state = AppState.shared
    @State private var selectedPID: Int32? = nil
    
    public init() {}
    
    var selectedApp: AudioApp? {
        state.apps.first(where: { $0.id == selectedPID })
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            
            // MARK: Canvas
            VStack(spacing: 0) {
                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spatial Soundstage")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("Drag nodes: Up = louder · Left/Right = stereo balance")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle(isOn: $state.showAllApps) {
                        Text("All Apps")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .toggleStyle(.checkbox)
                    
                    Button(action: {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                            state.resetToDefaults()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                            Text("Reset")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                
                Divider().opacity(0.3)
                
                // Canvas area
                GeometryReader { geo in
                    ZStack {
                        // Grid rings
                        ForEach([0.25, 0.5, 0.75], id: \.self) { frac in
                            Ellipse()
                                .stroke(Color.primary.opacity(0.05), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                                .frame(width: geo.size.width * frac, height: geo.size.height * frac)
                        }
                        
                        // Cross axes
                        Path { p in
                            let w = geo.size.width
                            let h = geo.size.height
                            p.move(to: CGPoint(x: w/2, y: 16))
                            p.addLine(to: CGPoint(x: w/2, y: h - 16))
                            p.move(to: CGPoint(x: 16, y: h/2))
                            p.addLine(to: CGPoint(x: w - 16, y: h/2))
                        }
                        .stroke(Color.primary.opacity(0.04), lineWidth: 1)
                        
                        // Axis labels
                        Text("LOUD").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                            .position(x: geo.size.width/2, y: 8)
                        Text("QUIET").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                            .position(x: geo.size.width/2, y: geo.size.height - 8)
                        Text("L").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                            .position(x: 8, y: geo.size.height/2)
                        Text("R").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                            .position(x: geo.size.width - 8, y: geo.size.height/2)
                        
                        // Center listener
                        VStack(spacing: 2) {
                            ZStack {
                                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 38, height: 38)
                                Circle().stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5).frame(width: 38, height: 38)
                                Image(systemName: "headphones").font(.system(size: 16)).foregroundStyle(Color.accentColor)
                            }
                            Text("YOU").font(.system(size: 7, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
                        }
                        .position(x: geo.size.width/2, y: geo.size.height/2)
                        
                        // App nodes
                        let displayApps = state.showAllApps ? state.apps : state.visibleApps
                        ForEach(displayApps) { app in
                            AppNodeView(
                                app: app,
                                canvasSize: geo.size,
                                isSelected: selectedPID == app.id,
                                onSelect: { selectedPID = app.id }
                            )
                        }
                    }
                }
                .padding(16)
            }
            .frame(minWidth: 420, maxWidth: .infinity, minHeight: 450, maxHeight: .infinity)
            
            Divider().opacity(0.3)
            
            // MARK: Inspector
            VStack(spacing: 0) {
                if let app = selectedApp {
                    ScrollView(showsIndicators: false) {
                        inspectorContent(for: app)
                    }
                } else {
                    emptyInspector
                }
            }
            .frame(width: 240)
            .background(.ultraThinMaterial)
        }
        .frame(width: 680, height: 480)
        .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
    }
    
    // MARK: - Inspector Content
    
    @ViewBuilder
    private func inspectorContent(for app: AudioApp) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(app.accentColor.opacity(0.12))
                        .frame(width: 42, height: 42)
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "app.fill").foregroundStyle(app.accentColor).font(.system(size: 18))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("PID \(app.pid)").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            
            Divider().opacity(0.3)
            
            // Output device
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader("OUTPUT DEVICE", icon: "speaker.wave.2")
                Menu {
                    ForEach(state.devices) { device in
                        Button(action: { state.setOutputDevice(for: app, to: device) }) {
                            HStack {
                                Text(device.name)
                                if app.outputDevice.id == device.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: deviceIcon(app.outputDevice.name)).font(.system(size: 10))
                        Text(app.outputDevice.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            
            Divider().opacity(0.3)
            
            // Volume
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("SPATIAL CONTROLS", icon: "scope")
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Volume").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("\(Int(app.volume * 100))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(app.accentColor)
                    }
                    Slider(value: Binding(
                        get: { app.volume },
                        set: { state.setVolume(for: app, to: $0) }
                    ), in: 0...1).tint(app.accentColor)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Stereo Position").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(stereoLabel(app.stereoPosition))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(app.accentColor)
                    }
                    Slider(value: Binding(
                        get: { app.stereoPosition },
                        set: { state.setStereoPosition(for: app, to: $0) }
                    ), in: -1...1).tint(app.accentColor)
                    HStack {
                        Text("L").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("C").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("R").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    }
                }
            }
            
            Divider().opacity(0.3)
            
            // Actions
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("ACTIONS", icon: "bolt")
                
                HStack(spacing: 6) {
                    actionButton(
                        label: app.isMuted ? "Unmute" : "Mute",
                        icon: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        isActive: app.isMuted,
                        action: { state.toggleMute(for: app) }
                    )
                    actionButton(
                        label: app.isRecording ? "Stop" : "Record",
                        icon: app.isRecording ? "stop.circle.fill" : "record.circle",
                        isActive: app.isRecording,
                        action: { state.toggleRecording(for: app) }
                    )
                }
                
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        state.snapToCenter(for: app)
                    }
                }) {
                    Label("Snap to Center", systemImage: "scope")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
        }
        .padding(16)
    }
    
    private var emptyInspector: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 24))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Select an App")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Tap any node on the soundstage to view and edit its settings.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
    }
    
    @ViewBuilder
    private func actionButton(label: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(isActive ? Color.red.opacity(0.1) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(isActive ? .red : .primary)
        }
        .buttonStyle(.plain)
    }
    
    private func stereoLabel(_ pos: Double) -> String {
        if pos < -0.05 { return "L \(Int(abs(pos) * 100))%" }
        if pos > 0.05 { return "R \(Int(pos * 100))%" }
        return "Center"
    }
    
    private func deviceIcon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpod") || n.contains("headphone") { return "airpodspro" }
        if n.contains("speaker") { return "hifispeaker.fill" }
        if n.contains("hdmi") || n.contains("display") { return "display" }
        return "speaker.wave.2.fill"
    }
}

// MARK: - Visual Effect

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = blendingMode; v.state = .active; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material; nsView.blendingMode = blendingMode
    }
}

#Preview { MainWindowView() }
