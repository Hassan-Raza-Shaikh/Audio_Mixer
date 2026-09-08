import SwiftUI

// MARK: - App Mixer Card

struct AppMixerCard: View {
    let app: AudioApp
    let isSelected: Bool
    @ObservedObject var state = AppState.shared

    var body: some View {
        VStack(spacing: 10) {
            // Header: icon + name + live meter
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(app.accentColor.opacity(0.12))
                        .frame(width: 34, height: 34)
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "app.fill").font(.system(size: 15)).foregroundStyle(app.accentColor)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(app.isKnownAudioApp ? "Audio app" : "Application")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if AudioCaptureEngine.shared.isCapturing(pid: app.pid) && !app.isMuted {
                    LevelBars(pid: app.pid, color: app.accentColor, barCount: 4)
                        .frame(width: 18, height: 14)
                }
            }

            // Volume
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                VolumeSlider(app: app)
                Text("\(Int(app.volume * 100))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            // Pan
            HStack(spacing: 8) {
                Text("Pan").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { app.stereoPosition },
                    set: { state.setStereoPosition(for: app, to: $0) }
                ), in: -1...1)
                .tint(app.accentColor)
                .controlSize(.mini)
                .disabled(app.isSpatialEnabled)
                Text(stereoLabel(app.stereoPosition))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .opacity(app.isSpatialEnabled ? 0.4 : 1.0)

            Divider().opacity(0.15)

            // Footer: device + mute + record
            HStack(spacing: 6) {
                Menu {
                    ForEach(state.devices) { device in
                        Button { state.setOutputDevice(for: app, to: device) } label: {
                            Label(device.name, systemImage: app.outputDevice.id == device.id ? "checkmark" : deviceSymbol(for: device.name))
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: deviceSymbol(for: app.outputDevice.name)).font(.system(size: 9))
                        Text(app.outputDevice.shortName).font(.system(size: 9, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()

                Spacer()

                iconButton(app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           active: app.isMuted, help: app.isMuted ? "Unmute" : "Mute") {
                    state.toggleMute(for: app)
                }
                iconButton(app.isRecording ? "stop.circle.fill" : "record.circle",
                           active: app.isRecording, help: app.isRecording ? "Stop recording" : "Record to ~/Music/Aura Recordings") {
                    state.toggleRecording(for: app)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? app.accentColor.opacity(0.6) : Color.primary.opacity(0.06),
                        lineWidth: isSelected ? 1.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
    }

    @ViewBuilder
    private func iconButton(_ icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.bouncy(duration: 0.3)) { action() } }) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(active ? Color.red : Color.primary.opacity(0.7))
                .frame(width: 24, height: 24)
                .background(active ? Color.red.opacity(0.12) : Color.primary.opacity(0.05), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func stereoLabel(_ pos: Double) -> String {
        if pos < -0.05 { return "L\(Int(abs(pos) * 100))" }
        if pos > 0.05 { return "R\(Int(pos * 100))" }
        return "C"
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
                if !app.isMuted {
                    Circle().stroke(app.accentColor.opacity(isDragging ? 0.6 : 0.25), lineWidth: 1.5)
                        .frame(width: 54, height: 54).blur(radius: 1)
                }
                if isSelected {
                    Circle().stroke(Color.white.opacity(0.95), lineWidth: 2)
                        .frame(width: 52, height: 52)
                        .shadow(color: app.accentColor.opacity(0.4), radius: 4)
                }
                Circle().fill(app.accentColor.opacity(0.12)).frame(width: 44, height: 44)

                if let icon = app.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24).opacity(app.isMuted ? 0.3 : 1.0)
                } else {
                    Image(systemName: "app.fill").font(.system(size: 14)).foregroundStyle(app.accentColor)
                }

                if app.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
                        .padding(1.5).background(.regularMaterial, in: Circle())
                        .offset(x: 12, y: -12)
                }

                Button {
                    withAnimation(.bouncy(duration: 0.4)) { state.toggleSpatial(for: app) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 6, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 12, height: 12).background(Color.red.opacity(0.8), in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: -12, y: -12)
                .help("Remove from soundstage")
            }
            .frame(width: 44, height: 44)
            .background(app.accentColor.opacity(0.1), in: Circle())
            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)

            Text(app.name)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(.regularMaterial, in: Capsule())
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
                    let isCenter = abs(nx - 0.5) < 0.03
                    state.setCanvasPosition(for: app, x: isCenter ? 0.5 : nx, y: ny)
                }
                .onEnded { _ in
                    isDragging = false
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                }
        )
        .onTapGesture { onSelect() }
    }
}

// MARK: - Main View

public struct MainWindowView: View {
    @ObservedObject var state = AppState.shared
    @State private var selectedPID: Int32? = nil
    @Environment(\.appearsActive) private var appearsActive

    public init() {}

    var selectedApp: AudioApp? { state.apps.first(where: { $0.id == selectedPID }) }
    private var displayApps: [AudioApp] { state.showAllApps ? state.apps : state.visibleApps }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)

            if !state.hasCapturePermission {
                PermissionBanner()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            HStack(spacing: 0) {
                Group {
                    if state.activeTab == "mixer" {
                        mixerTab
                    } else {
                        spatialTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().opacity(0.3)
                inspectorSidebar
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.activeTab)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 560)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
        .opacity(appearsActive ? 1.0 : 0.9)
        .animation(.easeInOut(duration: 0.25), value: appearsActive)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Aura").font(.system(size: 15, weight: .bold, design: .rounded))
                Text("Per-app audio mixer").font(.system(size: 9)).foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $state.activeTab) {
                Label("Mixer", systemImage: "square.grid.2x2").tag("mixer")
                Label("Spatial", systemImage: "circle.hexagongrid").tag("spatial")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Spacer()

            Picker("", selection: $state.showAllApps) {
                Text("Audio").tag(false)
                Text("All").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)

            ScreenRecordControl()

            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { state.resetToDefaults() }
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold)).padding(5)
            }
            .buttonStyle(.plain)
            .help("Reset all volumes, mutes and routes")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Mixer tab

    private var mixerTab: some View {
        ScrollView(showsIndicators: false) {
            if displayApps.isEmpty {
                emptyDashboard
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 280), spacing: 12)], spacing: 12) {
                    ForEach(displayApps) { app in
                        AppMixerCard(app: app, isSelected: selectedPID == app.id)
                            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selectedPID = app.id } }
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Spatial tab

    private var spatialTab: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    ForEach([0.2, 0.4, 0.6, 0.8], id: \.self) { frac in
                        Circle().stroke(Color.primary.opacity(0.04), lineWidth: 1)
                            .frame(width: geo.size.width * frac, height: geo.size.width * frac)
                    }
                    Path { p in
                        let w = geo.size.width, h = geo.size.height
                        p.move(to: CGPoint(x: w/2, y: 0)); p.addLine(to: CGPoint(x: w/2, y: h))
                        p.move(to: CGPoint(x: 0, y: h/2)); p.addLine(to: CGPoint(x: w, y: h/2))
                    }
                    .stroke(Color.primary.opacity(0.03), lineWidth: 1)

                    compassLabel("LOUD", x: geo.size.width/2, y: 12)
                    compassLabel("QUIET", x: geo.size.width/2, y: geo.size.height - 12)
                    compassLabel("L", x: 12, y: geo.size.height/2)
                    compassLabel("R", x: geo.size.width - 12, y: geo.size.height/2)

                    VStack(spacing: 2) {
                        ZStack {
                            Circle().fill(Color.accentColor.opacity(0.08)).frame(width: 34, height: 34)
                            Circle().stroke(Color.accentColor.opacity(0.4), lineWidth: 1).frame(width: 34, height: 34)
                            Image(systemName: "headphones").font(.system(size: 14)).foregroundStyle(Color.accentColor)
                        }
                        Text("YOU").font(.system(size: 7, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
                    }
                    .position(x: geo.size.width/2, y: geo.size.height/2)

                    ForEach(displayApps.filter { $0.isSpatialEnabled }) { app in
                        SpatialNodeView(app: app, canvasSize: geo.size, isSelected: selectedPID == app.id) {
                            withAnimation(.bouncy) { selectedPID = app.id }
                        }
                    }
                }
            }
            .padding(10)

            Divider().opacity(0.2)
            spatialTray
        }
    }

    private func compassLabel(_ text: String, x: CGFloat, y: CGFloat) -> some View {
        Text(text).font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary).position(x: x, y: y)
    }

    private var spatialTray: some View {
        let nonSpatial = displayApps.filter { !$0.isSpatialEnabled }
        return HStack {
            if nonSpatial.isEmpty {
                Text("All apps are on the soundstage.")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Text("ADD:").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                        ForEach(nonSpatial) { app in
                            Button {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { state.toggleSpatial(for: app) }
                            } label: {
                                HStack(spacing: 5) {
                                    if let icon = app.icon {
                                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                                    } else {
                                        Image(systemName: "app.fill").font(.system(size: 10)).foregroundStyle(app.accentColor)
                                    }
                                    Text(app.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                                    Image(systemName: "plus.circle.fill").font(.system(size: 9)).foregroundStyle(app.accentColor)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .frame(height: 40)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Inspector

    private var inspectorSidebar: some View {
        VStack(spacing: 0) {
            if let app = selectedApp {
                ScrollView(showsIndicators: false) { inspectorContent(for: app) }
            } else {
                emptyInspector
            }
        }
        .frame(width: 250)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private func inspectorContent(for app: AudioApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(app.accentColor.opacity(0.12)).frame(width: 36, height: 36)
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "app.fill").foregroundStyle(app.accentColor).font(.system(size: 14))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 13, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(app.bundleId).font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
            }

            Divider().opacity(0.2)

            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("OUTPUT DEVICE", icon: "speaker.wave.2")
                Menu {
                    ForEach(state.devices) { device in
                        Button { state.setOutputDevice(for: app, to: device) } label: {
                            Label(device.name, systemImage: app.outputDevice.id == device.id ? "checkmark" : deviceSymbol(for: device.name))
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: deviceSymbol(for: app.outputDevice.name)).font(.system(size: 9))
                        Text(app.outputDevice.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }

            Divider().opacity(0.2)

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("CHANNEL", icon: "slider.horizontal.3")

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Volume").font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text("\(Int(app.volume * 100))%").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(app.accentColor)
                    }
                    Slider(value: Binding(get: { app.volume }, set: { state.setVolume(for: app, to: $0) }), in: 0...1).tint(app.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Stereo Balance").font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text(stereoLabel(app.stereoPosition)).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(app.accentColor)
                    }
                    Slider(value: Binding(get: { app.stereoPosition }, set: { state.setStereoPosition(for: app, to: $0) }), in: -1...1)
                        .tint(app.accentColor)
                        .disabled(app.isSpatialEnabled)
                }
            }

            Divider().opacity(0.2)

            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("ACTIONS", icon: "bolt")
                HStack(spacing: 6) {
                    actionButton(app.isMuted ? "Unmute" : "Mute",
                                 icon: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                 isActive: app.isMuted) { state.toggleMute(for: app) }
                    actionButton(app.isRecording ? "Stop" : "Record",
                                 icon: app.isRecording ? "stop.circle.fill" : "record.circle",
                                 isActive: app.isRecording) { state.toggleRecording(for: app) }
                }
                Button {
                    withAnimation(.bouncy(duration: 0.5)) {
                        state.snapToCenter(for: app)
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    }
                } label: {
                    Label("Reset Channel", systemImage: "scope")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.2)

            // Spatial placement (secondary feature)
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("SPATIAL", icon: "circle.hexagongrid")
                Toggle(isOn: Binding(get: { app.isSpatialEnabled }, set: { _ in
                    withAnimation(.bouncy(duration: 0.4)) { state.toggleSpatial(for: app) }
                })) {
                    Text("Place on soundstage").font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(SwitchToggleStyle(tint: app.accentColor))
                Text("When on, drag the app in the Spatial tab to set its volume and stereo balance by position.")
                    .font(.system(size: 8)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var emptyDashboard: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.circle").font(.system(size: 30)).foregroundStyle(.secondary.opacity(0.4))
            Text(state.showAllApps ? "No running apps" : "No audio apps running")
                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text("Start playing audio in an app and it'll appear here.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var emptyInspector: some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.tap.fill").font(.system(size: 20)).foregroundStyle(.secondary.opacity(0.4))
            Text("Select an app").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text("Pick a card or soundstage node to edit its channel.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func actionButton(_ label: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(isActive ? Color.red.opacity(0.1) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isActive ? .red : .primary)
        }
        .buttonStyle(.plain)
    }

    private func stereoLabel(_ pos: Double) -> String {
        if pos < -0.05 { return "L \(Int(abs(pos) * 100))%" }
        if pos > 0.05 { return "R \(Int(pos * 100))%" }
        return "Center"
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
