import SwiftUI

struct AppNodeView: View {
    let app: AudioApp
    let size: CGSize
    @ObservedObject var state = AppState.shared
    
    // Local drag coordinates
    @State private var dragOffset = CGSize.zero
    @State private var isDragging = false
    
    var body: some View {
        // Position calculation based on AppState pan and volume
        // pan is -1.0 to 1.0 (X axis)
        // distance represents volume (Y axis, closer to center = louder/higher volume)
        let centerX = size.width / 2
        let centerY = size.height / 2
        let radiusX = (size.width - 60) / 2
        let radiusY = (size.height - 60) / 2
        
        // Calculate coordinate from state
        let posX = centerX + CGFloat(app.pan) * radiusX
        let posY = centerY - CGFloat(app.volume) * radiusY
        
        return VStack(spacing: 4) {
            ZStack {
                // Glow behind the icon matching the app color
                Circle()
                    .fill(app.accentColor.opacity(isDragging ? 0.35 : 0.15))
                    .frame(width: 48, height: 48)
                    .blur(radius: isDragging ? 8 : 4)
                
                // Outer ring
                Circle()
                    .stroke(app.accentColor.opacity(isDragging ? 0.8 : 0.4), lineWidth: 1.5)
                    .frame(width: 48, height: 48)
                
                // Icon representation
                Image(systemName: app.name == "Spotify" ? "music.note" :
                        (app.name.contains("Zoom") ? "video.fill" :
                        (app.name == "Safari" ? "safari.fill" : "app.badge")))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(app.accentColor)
            }
            
            Text(app.name)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        }
        .scaleEffect(isDragging ? 1.2 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isDragging)
        .position(x: posX, y: posY)
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    // Calculate pan (-1 to 1) based on X relative to center
                    let dx = value.location.x - centerX
                    let relativePan = max(-1.0, min(1.0, dx / radiusX))
                    
                    // Calculate volume (0 to 1) based on distance from bottom (Y axis)
                    let dy = centerY - value.location.y
                    let relativeVol = max(0.0, min(1.0, dy / radiusY))
                    
                    state.setPan(for: app, to: Double(relativePan))
                    state.setVolume(for: app, to: Double(relativeVol))
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}

public struct MainWindowView: View {
    @ObservedObject var state = AppState.shared
    @State private var selectedAppId: UUID? = nil
    
    public init() {}
    
    var selectedApp: AudioApp? {
        state.apps.first(where: { $0.id == selectedAppId })
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            // Main Spatial canvas
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spatial Soundstage")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("Drag application nodes to position them in 3D binaural space")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(20)
                
                Divider()
                    .opacity(0.3)
                
                // Soundstage Plotting Grid
                GeometryReader { geometry in
                    ZStack {
                        // Concentric circular speaker rings
                        ForEach([0.3, 0.6, 0.9], id: \.self) { fraction in
                            Circle()
                                .stroke(Color.primary.opacity(0.04), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .frame(width: geometry.size.width * fraction, height: geometry.size.height * fraction)
                        }
                        
                        // Center axis lines
                        Path { path in
                            path.move(to: CGPoint(x: geometry.size.width / 2, y: 30))
                            path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height - 30))
                            path.move(to: CGPoint(x: 30, y: geometry.size.height / 2))
                            path.addLine(to: CGPoint(x: geometry.size.width - 30, y: geometry.size.height / 2))
                        }
                        .stroke(Color.primary.opacity(0.03), lineWidth: 1)
                        
                        // Center Listener Icon (User Head)
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.1))
                                    .frame(width: 44, height: 44)
                                
                                Circle()
                                    .stroke(Color.accentColor, lineWidth: 1.5)
                                    .frame(width: 44, height: 44)
                                
                                Image(systemName: "headphones")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text("YOU")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.accentColor)
                        }
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        
                        // App nodes
                        ForEach(state.apps) { app in
                            AppNodeView(app: app, size: geometry.size)
                                .onTapGesture {
                                    selectedAppId = app.id
                                }
                        }
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 420, maxWidth: .infinity, minHeight: 450, maxHeight: .infinity)
            
            // Side Inspector Panel
            Divider()
                .opacity(0.3)
            
            VStack(spacing: 0) {
                if let app = selectedApp {
                    VStack(alignment: .leading, spacing: 16) {
                        // Title / Header
                        HStack {
                            ZStack {
                                Circle()
                                    .fill(app.accentColor.opacity(0.1))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundStyle(app.accentColor)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                Text("PID: \(app.pid) • \(app.bundleId)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        
                        Divider()
                            .opacity(0.5)
                        
                        // Volume / Panning meters
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SPATIAL CONTROLS")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Volume (\(Int(app.volume * 100))%)")
                                    .font(.system(size: 11, weight: .medium))
                                Slider(value: Binding(
                                    get: { app.volume },
                                    set: { state.setVolume(for: app, to: $0) }
                                ), in: 0...1)
                                .tint(app.accentColor)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                let panText: String = {
                                    if app.pan < -0.05 {
                                        return "Left (\(Int(abs(app.pan) * 100))%)"
                                    } else if app.pan > 0.05 {
                                        return "Right (\(Int(app.pan) * 100))%)"
                                    } else {
                                        return "Center"
                                    }
                                }()
                                Text("Panning: \(panText)")
                                    .font(.system(size: 11, weight: .medium))
                                Slider(value: Binding(
                                    get: { app.pan },
                                    set: { state.setPan(for: app, to: $0) }
                                ), in: -1...1)
                                .tint(app.accentColor)
                            }
                        }
                        
                        // Fake EQ sliders (Voice boost presets)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("10-BAND PARAMETRIC EQUALIZER")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 8) {
                                ForEach(0..<5) { idx in
                                    VStack {
                                        Slider(value: .constant(Double.random(in: 0.3...0.8)), in: 0...1)
                                            .controlSize(.mini)
                                            .tint(app.accentColor)
                                            // Vertical Slider rotation helper
                                            .frame(width: 44, height: 60)
                                            .rotationEffect(.degrees(-90))
                                        Text("\(50 * (idx + 1))Hz")
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(height: 90)
                        }
                        
                        Spacer()
                        
                        // Quick Actions
                        HStack {
                            Button(action: { state.toggleMute(for: app) }) {
                                HStack {
                                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    Text(app.isMuted ? "Unmute" : "Mute")
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(app.isMuted ? Color.red.opacity(0.1) : Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(app.isMuted ? .red : .primary)
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: { state.toggleRecording(for: app) }) {
                                HStack {
                                    Image(systemName: "record.circle")
                                    Text(app.isRecording ? "Stop Recording" : "Record App")
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(app.isRecording ? Color.red.opacity(0.1) : Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(app.isRecording ? .red : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "cursorarrow.click.2")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("Select App Node")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("Click any node on the soundstage to open the channel inspector.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 250)
            .background(.ultraThinMaterial)
        }
        .frame(width: 670, height: 450)
        .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
    }
}

// Helper NSVisualEffectView wrapper for native vibrant window backgrounds
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

#Preview {
    MainWindowView()
}
