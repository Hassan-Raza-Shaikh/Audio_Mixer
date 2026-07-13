import SwiftUI

// MARK: - GPU-driven EQ Bars (TimelineView + Canvas)
struct MinimalEQBars: View {
    let app: AudioApp
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                
                // Get the real peak amplitude from the hardware audio capture engine
                let realPeak = AudioCaptureEngine.shared.getPeak(for: app.pid)
                let amplitude = Double(realPeak > 0.002 ? min(1.0, realPeak * 2.5) : 0.0)
                
                let barCount = 4
                let gap: CGFloat = 1.0
                let barW = (size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
                let freqs: [Double] = [3.1, 4.2, 2.5, 3.8]
                let phases: [Double] = [0.0, 1.1, 2.2, 3.3]

                for i in 0..<barCount {
                    let swing = sin(t * freqs[i] + phases[i]) * 0.4 + 0.6
                    let h = size.height * CGFloat(swing * amplitude)
                    let x = CGFloat(i) * (barW + gap)
                    let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(app.accentColor.opacity(0.85)))
                }
            }
        }
        .opacity(isActive ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.35), value: isActive)
    }
}

// MARK: - Control Center Style Volume Slider
struct DashboardVolumeSlider: View {
    let app: AudioApp
    @ObservedObject var state = AppState.shared
    @State private var isDragging = false
    @State private var isHovering = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(isHovering ? 0.12 : 0.05), lineWidth: 0.5)
                    )
                
                // Volume Fill with integrated wave visualization
                if !app.isMuted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(app.accentColor.opacity(0.2))
                        .frame(width: geo.size.width * CGFloat(app.volume))
                    
                    // Wave graphic inside fader - pass app instead of accentColor
                    MinimalEQBars(app: app, isActive: app.isKnownAudioApp && !app.isMuted)
                        .frame(width: max(10, geo.size.width * CGFloat(app.volume) - 20), height: 12)
                        .padding(.leading, 8)
                        .opacity(0.3)
                    
                    // Core slider line (very subtle white highlight)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(app.accentColor)
                        .frame(width: max(4, geo.size.width * CGFloat(app.volume)))
                        .mask(
                            HStack {
                                Spacer()
                                Rectangle().frame(width: 4).foregroundStyle(.white)
                            }
                            .frame(width: geo.size.width * CGFloat(app.volume))
                        )
                }
                
                // Glass shine
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LinearGradient(
                        colors: [.white.opacity(0.2), .clear, .white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 0.5)
                
                // Volume Text inside fader
                HStack {
                    Text("Volume")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(app.volume * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    isDragging = true
                    state.setVolume(for: app, to: max(0, min(1, Double(g.location.x / geo.size.width))))
                }
                .onEnded { _ in isDragging = false }
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            }
        }
        .frame(height: 24)
        .scaleEffect(isDragging ? 1.02 : 1.0)
        .animation(.bouncy(duration: 0.2), value: isDragging)
    }
}

// MARK: - App Mixer Card
struct AppMixerCard: View {
    let app: AudioApp
    @ObservedObject var state = AppState.shared
    
    var body: some View {
        VStack(spacing: 10) {
            // Header: Icon + Info + Spatial Toggle
            HStack(spacing: 8) {
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
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text("PID \(app.pid)")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                // Spatial Toggle
                Button(action: {
                    withAnimation(.bouncy(duration: 0.4)) {
                        state.toggleSpatial(for: app)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: app.isSpatialEnabled ? "waveform.and.mic" : "waveform")
                            .font(.system(size: 8, weight: .bold))
                        Text("Spatial")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .foregroundStyle(app.isSpatialEnabled ? Color.white : .secondary)
                    .background(
                        app.isSpatialEnabled ?
                        AnyView(LinearGradient(colors: [app.accentColor, app.accentColor.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                        AnyView(Color.primary.opacity(0.05))
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            
            DashboardVolumeSlider(app: app)
            
            // Pan slider
            HStack(spacing: 8) {
                Text("Pan")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                
                Slider(value: Binding(
                    get: { app.stereoPosition },
                    set: { state.setStereoPosition(for: app, to: $0) }
                ), in: -1...1)
                .tint(app.accentColor)
                .disabled(app.isSpatialEnabled)
                
                Text(stereoLabel(app.stereoPosition))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .opacity(app.isSpatialEnabled ? 0.4 : 1.0)
            
            Divider().opacity(0.2)
            
            // Bottom bar
            HStack {
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
                    HStack(spacing: 2) {
                        Image(systemName: deviceIcon(app.outputDevice.name)).font(.system(size: 9))
                        Text(app.outputDevice.shortName)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 6))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 130)
                
                Spacer()
                
                HStack(spacing: 6) {
                    Button(action: { state.toggleMute(for: app) }) {
                        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(app.isMuted ? Color.red : Color.primary.opacity(0.7))
                            .frame(width: 20, height: 20)
                            .background(app.isMuted ? Color.red.opacity(0.1) : Color.primary.opacity(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { state.toggleRecording(for: app) }) {
                        Image(systemName: app.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(app.isRecording ? Color.red : Color.primary.opacity(0.7))
                            .frame(width: 20, height: 20)
                            .background(app.isRecording ? Color.red.opacity(0.1) : Color.primary.opacity(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .glassEffect(.regular.tint(app.isSpatialEnabled ? app.accentColor.opacity(0.03) : .clear), in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
    
    private func stereoLabel(_ pos: Double) -> String {
        if pos < -0.05 { return "L\(Int(abs(pos)*100))" }
        if pos > 0.05 { return "R\(Int(pos*100))" }
        return "C"
    }
    
    private func deviceIcon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpod") || n.contains("headphone") { return "airpodspro" }
        if n.contains("speaker") { return "hifispeaker.fill" }
        if n.contains("hdmi") || n.contains("display") { return "display" }
        return "speaker.wave.2.fill"
    }
}

// MARK: - Spatial Node View
struct SpatialNodeView: View {
    let app: AudioApp
    let canvasSize: CGSize
    let isSelected: Bool
    let onSelect: () -> Void
    @ObservedObject var state = AppState.shared
    
    @State private var isDragging = false
    
    var posX: CGFloat { CGFloat(app.canvasX) * canvasSize.width }
    var posY: CGFloat { CGFloat(app.canvasY) * canvasSize.height }
    
    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                // Radar sweep/pulse ring
                if !app.isMuted {
                    Circle()
                        .stroke(app.accentColor.opacity(isDragging ? 0.6 : 0.25), lineWidth: 1.5)
                        .frame(width: 54, height: 54)
                        .blur(radius: 1)
                }
                
                if isSelected {
                    Circle()
                        .stroke(Color.white.opacity(0.95), lineWidth: 2)
                        .frame(width: 52, height: 52)
                        .shadow(color: app.accentColor.opacity(0.4), radius: 4)
                }
                
                // Color glow ring
                Circle()
                    .fill(app.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                
                // App icon
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .opacity(app.isMuted ? 0.3 : 1.0)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(app.accentColor)
                }
                
                // Muted/Spatial markers
                if app.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(1.5)
                        .glassEffect(.regular, in: Circle())
                        .offset(x: 12, y: -12)
                }
                
                // Close button to remove from soundstage
                Button(action: {
                    withAnimation(.bouncy(duration: 0.4)) {
                        state.toggleSpatial(for: app)
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 12, height: 12)
                        .background(Color.red.opacity(0.8))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: -12, y: -12)
            }
            .frame(width: 44, height: 44)
            .glassEffect(.regular.tint(app.accentColor.opacity(0.1)).interactive(), in: Circle())
            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
            
            Text(app.name)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .glassEffect(.regular, in: .capsule)
        }
        .scaleEffect(isDragging ? 1.15 : (isSelected ? 1.05 : 1.0))
        .animation(.bouncy(duration: 0.35), value: isDragging || isSelected)
        .position(x: posX, y: posY)
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    }
                    let nx = max(0.05, min(0.95, Double(value.location.x / canvasSize.width)))
                    let ny = max(0.05, min(0.95, Double(value.location.y / canvasSize.height)))
                    
                    // Center snap
                    let isCenter = abs(nx - 0.5) < 0.03
                    let finalNx = isCenter ? 0.5 : nx
                    
                    if isCenter && abs(app.canvasX - 0.5) >= 0.03 {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    }
                    
                    state.setCanvasPosition(for: app, x: finalNx, y: ny)
                }
                .onEnded { _ in
                    isDragging = false
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                }
        )
        .onTapGesture {
            onSelect()
        }
    }
}

// MARK: - Main View
public struct MainWindowView: View {
    @ObservedObject var state = AppState.shared
    @State private var selectedPID: Int32? = nil
    @Environment(\.appearsActive) private var appearsActive
    
    public init() {}
    
    var selectedApp: AudioApp? {
        state.apps.first(where: { $0.id == selectedPID })
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Native Apple Style Toolbar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aura")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Spatial Sound Console")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Segmented mode switcher
                Picker("", selection: $state.activeTab) {
                    Label("Dashboard", systemImage: "square.grid.2x2").tag("mixer")
                    Label("Spatial Radar", systemImage: "radar").tag("spatial")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                
                Spacer()
                
                Toggle(isOn: $state.showAllApps) {
                    Text("All Apps").font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(.checkbox)
                
                Button(action: {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                        state.resetToDefaults()
                    }
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(5)
                }
                .glassEffect(.regular, in: Circle())
                .buttonStyle(.plain)
                .help("Reset spatial parameters")
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 12)
            
            Divider().opacity(0.3)
            
            // Tab contents
            HStack(spacing: 0) {
                if state.activeTab == "mixer" {
                    // TAB 1: Control Center Dashboard
                    ScrollView(showsIndicators: false) {
                        let displayApps = state.showAllApps ? state.apps : state.visibleApps
                        if displayApps.isEmpty {
                            emptyDashboard
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 230), spacing: 12)], spacing: 12) {
                                ForEach(displayApps) { app in
                                    AppMixerCard(app: app)
                                        .onTapGesture {
                                            selectedPID = app.id
                                        }
                                }
                            }
                            .padding(14)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                    
                } else {
                    // TAB 2: Spatial Radar View
                    VStack(spacing: 0) {
                        GeometryReader { geo in
                            ZStack {
                                // Radar rings
                                ForEach([0.2, 0.4, 0.6, 0.8], id: \.self) { frac in
                                    Circle()
                                        .stroke(Color.primary.opacity(0.04), lineWidth: 1)
                                        .frame(width: geo.size.width * frac, height: geo.size.width * frac)
                                }
                                
                                // Radar sweep lines
                                Path { p in
                                    let w = geo.size.width
                                    let h = geo.size.height
                                    p.move(to: CGPoint(x: w/2, y: 0))
                                    p.addLine(to: CGPoint(x: w/2, y: h))
                                    p.move(to: CGPoint(x: 0, y: h/2))
                                    p.addLine(to: CGPoint(x: w, y: h/2))
                                }
                                .stroke(Color.primary.opacity(0.03), lineWidth: 1)
                                
                                // Compass markers
                                Text("LOUD").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                                    .position(x: geo.size.width/2, y: 10)
                                Text("QUIET").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                                    .position(x: geo.size.width/2, y: geo.size.height - 10)
                                Text("L").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                                    .position(x: 10, y: geo.size.height/2)
                                Text("R").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                                    .position(x: geo.size.width - 10, y: geo.size.height/2)
                                
                                // Listener
                                VStack(spacing: 2) {
                                    ZStack {
                                        Circle().fill(Color.accentColor.opacity(0.08)).frame(width: 34, height: 34)
                                        Circle().stroke(Color.accentColor.opacity(0.4), lineWidth: 1).frame(width: 34, height: 34)
                                        Image(systemName: "headphones").font(.system(size: 14)).foregroundStyle(Color.accentColor)
                                    }
                                    Text("YOU").font(.system(size: 7, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
                                }
                                .position(x: geo.size.width/2, y: geo.size.height/2)
                                
                                // Spatial nodes on the soundstage
                                let spatialApps = (state.showAllApps ? state.apps : state.visibleApps).filter { $0.isSpatialEnabled }
                                ForEach(spatialApps) { app in
                                    SpatialNodeView(
                                        app: app,
                                        canvasSize: geo.size,
                                        isSelected: selectedPID == app.id,
                                        onSelect: {
                                            withAnimation(.bouncy) { selectedPID = app.id }
                                        }
                                    )
                                }
                            }
                        }
                        .padding(10)
                        
                        Divider().opacity(0.2)
                        
                        // Tray of non-spatial apps (Place on radar)
                        let nonSpatialApps = (state.showAllApps ? state.apps : state.visibleApps).filter { !$0.isSpatialEnabled }
                        HStack {
                            if nonSpatialApps.isEmpty {
                                Text("All apps are on the soundstage.")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 8)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        Text("DOCK TRAY:").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                                        
                                        ForEach(nonSpatialApps) { app in
                                            Button(action: {
                                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                                    state.toggleSpatial(for: app)
                                                }
                                            }) {
                                                HStack(spacing: 5) {
                                                    if let icon = app.icon {
                                                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                                                    } else {
                                                        Image(systemName: "app.fill").font(.system(size: 10)).foregroundStyle(app.accentColor)
                                                    }
                                                    Text(app.name).font(.system(size: 9, weight: .medium))
                                                    Image(systemName: "plus.circle.fill")
                                                        .font(.system(size: 9))
                                                        .foregroundStyle(app.accentColor)
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .glassEffect(.regular, in: .capsule)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                }
                            }
                        }
                        .frame(height: 38)
                        .background(Color.black.opacity(0.04))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                }
                
                Divider().opacity(0.3)
                
                // Channels Sidebar Inspector
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
                .background(Color.black.opacity(0.08))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.activeTab)
        }
        .frame(width: 780, height: 500)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
        .opacity(appearsActive ? 1.0 : 0.88)
        .animation(.easeInOut(duration: 0.25), value: appearsActive)
    }
    
    // MARK: - Inspector Panel
    @ViewBuilder
    private func inspectorContent(for app: AudioApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(app.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "app.fill").foregroundStyle(app.accentColor).font(.system(size: 14))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("PID \(app.pid)").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            
            Divider().opacity(0.2)
            
            // Spatial Routing State
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("SPATIAL AUDIO ROUTING", icon: "waveform.and.mic")
                Toggle(isOn: Binding(
                    get: { app.isSpatialEnabled },
                    set: { _ in
                        withAnimation(.bouncy(duration: 0.4)) {
                            state.toggleSpatial(for: app)
                        }
                    }
                )) {
                    Text("Place on Soundstage")
                        .font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(SwitchToggleStyle(tint: app.accentColor))
                
                Text(app.isSpatialEnabled ? 
                     "Audio balance and volume are controlled by coordinates on the 2D soundstage." : 
                     "Behaving as a standard channel. Coordinates do not affect audio output.")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            
            Divider().opacity(0.2)
            
            // Output device
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("OUTPUT ROUTE", icon: "speaker.wave.2")
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
                        Image(systemName: deviceIcon(app.outputDevice.name)).font(.system(size: 9))
                        Text(app.outputDevice.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            
            Divider().opacity(0.2)
            
            // Manual Controls
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("CHANNEL STRIP", icon: "slider.horizontal.3")
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Volume").font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text("\(Int(app.volume * 100))%")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(app.accentColor)
                    }
                    Slider(value: Binding(
                        get: { app.volume },
                        set: { state.setVolume(for: app, to: $0) }
                    ), in: 0...1).tint(app.accentColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Stereo Balance").font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text(stereoLabel(app.stereoPosition))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(app.accentColor)
                    }
                    Slider(value: Binding(
                        get: { app.stereoPosition },
                        set: { state.setStereoPosition(for: app, to: $0) }
                    ), in: -1...1).tint(app.accentColor)
                    .disabled(app.isSpatialEnabled)
                    
                    HStack {
                        Text("L").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("C").font(.system(size: 7)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("R").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                    }
                }
            }
            
            Divider().opacity(0.2)
            
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
                    withAnimation(.bouncy(duration: 0.5, extraBounce: 0.2)) {
                        state.snapToCenter(for: app)
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    }
                }) {
                    Label("Snap to Center", systemImage: "scope")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
        }
        .padding(12)
    }
    
    private var emptyDashboard: some View {
        VStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("No active apps")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Ensure target audio-producing applications are running.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyInspector: some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 20))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Select an App")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Select any app card or soundstage node to edit details.")
                .font(.system(size: 9))
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
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
    }
    
    @ViewBuilder
    private func actionButton(label: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(isActive ? Color.red.opacity(0.1) : Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
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

