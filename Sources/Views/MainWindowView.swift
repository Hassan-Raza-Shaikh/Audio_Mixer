import SwiftUI

// MARK: - App Mixer Card

struct AppMixerCard: View {
    let app: AudioApp
    let isSelected: Bool
    @ObservedObject var state = AppState.shared

    private var isRouted: Bool { AudioRouter.shared.isRouting(app.id) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                AppIconView(app: app, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if isRouted && !app.isMuted {
                    LevelBars(pid: app.id, color: app.accentColor)
                        .frame(width: 18, height: 14)
                } else {
                    PlayingIndicator(isPlaying: app.isPlaying, color: app.accentColor)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                VolumeSlider(app: app)
                Text("\(Int((app.volume * 100).rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Text("Pan").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { app.stereoPosition },
                                      set: { state.setStereoPosition(for: app, to: $0) }), in: -1...1)
                    .tint(app.accentColor)
                    .controlSize(.mini)
                    .disabled(app.isSpatialEnabled)
                    .accessibilityLabel("\(app.name) balance")
                    .accessibilityValue(balanceLabel(app.stereoPosition))
                Text(shortBalance(app.stereoPosition))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .opacity(app.isSpatialEnabled ? 0.4 : 1)

            Divider().opacity(0.15)

            HStack(spacing: 6) {
                OutputDeviceMenu(app: app)
                Spacer()
                CircleIconButton(systemImage: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                 label: app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)",
                                 isActive: app.isMuted, size: 24) {
                    withAnimation(.bouncy(duration: 0.3)) { state.toggleMute(for: app) }
                }
                CircleIconButton(systemImage: app.isRecording ? "stop.circle.fill" : "record.circle",
                                 label: app.isRecording ? "Stop recording \(app.name)" : "Record \(app.name)’s audio",
                                 isActive: app.isRecording, size: 24) {
                    state.toggleRecording(for: app)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? app.accentColor.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.name)
    }

    private var statusText: String {
        if app.isPlaying { return isRouted ? "Playing · controlled by Aura" : "Playing" }
        return app.hasAudio ? "Silent" : "Hasn’t used audio yet"
    }
}

func shortBalance(_ pos: Double) -> String {
    if pos < -0.05 { return "L\(Int((abs(pos) * 100).rounded()))" }
    if pos > 0.05 { return "R\(Int((pos * 100).rounded()))" }
    return "C"
}

func balanceLabel(_ pos: Double) -> String {
    if pos < -0.05 { return "\(Int((abs(pos) * 100).rounded())) percent left" }
    if pos > 0.05 { return "\(Int((pos * 100).rounded())) percent right" }
    return "Centered"
}

// MARK: - Spatial Node

struct SpatialNodeView: View {
    let app: AudioApp
    let canvasSize: CGSize
    let isSelected: Bool
    let onSelect: () -> Void
    @ObservedObject var state = AppState.shared
    @State private var isDragging = false

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
                AppIconView(app: app, size: 44)
                    .clipShape(Circle())
                    .opacity(app.isMuted ? 0.4 : 1)
                if app.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
                        .padding(2).background(.regularMaterial, in: Circle())
                        .offset(x: 14, y: -14)
                }
            }
            .frame(width: 54, height: 54)
            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)

            Text(app.name)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(.regularMaterial, in: Capsule())
        }
        .scaleEffect(isDragging ? 1.15 : (isSelected ? 1.05 : 1))
        .animation(.bouncy(duration: 0.35), value: isDragging || isSelected)
        .position(x: CGFloat(app.canvasX) * canvasSize.width, y: CGFloat(app.canvasY) * canvasSize.height)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    }
                    let nx = max(0.05, min(0.95, Double(value.location.x / canvasSize.width)))
                    let ny = max(0.05, min(0.95, Double(value.location.y / canvasSize.height)))
                    state.setCanvasPosition(for: app, x: abs(nx - 0.5) < 0.03 ? 0.5 : nx, y: ny)
                }
                .onEnded { _ in
                    isDragging = false
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                }
        )
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Remove from Soundstage") { withAnimation(.bouncy) { state.toggleSpatial(for: app) } }
        }
        .accessibilityElement()
        .accessibilityLabel("\(app.name), volume \(Int((app.volume * 100).rounded())) percent, \(balanceLabel(app.stereoPosition))")
        .accessibilityAction(named: "Remove from soundstage") { state.toggleSpatial(for: app) }
    }
}

// MARK: - Main Window

struct MainWindowView: View {
    @ObservedObject var state = AppState.shared
    @State private var selectedPID: pid_t?

    private var selectedApp: AudioApp? { state.apps.first { $0.id == selectedPID } }
    private var displayApps: [AudioApp] { state.visibleApps }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)

            VStack(spacing: 8) {
                if state.audioAccessLikelyDenied { AudioAccessBanner() }
                if let notice = state.notice { NoticeBanner(notice: notice) }
            }
            .padding(.horizontal, 16)
            .padding(.top, state.audioAccessLikelyDenied || state.notice != nil ? 12 : 0)
            .animation(.easeOut(duration: 0.2), value: state.notice)

            HStack(spacing: 0) {
                Group {
                    if state.activeTab == "mixer" { mixerTab } else { spatialTab }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().opacity(0.3)
                inspector
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.activeTab)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 500, idealHeight: 580)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Aura").font(.system(size: 15, weight: .bold, design: .rounded))
                Text("Per-app audio mixer").font(.system(size: 9)).foregroundStyle(.secondary)
            }

            Spacer()

            Picker("View", selection: $state.activeTab) {
                Label("Mixer", systemImage: "square.grid.2x2").tag("mixer")
                Label("Spatial", systemImage: "circle.hexagongrid").tag("spatial")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Spacer()

            Picker("Show", selection: $state.showAllApps) {
                Text("Audio").tag(false)
                Text("All").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .help("Show apps that use audio, or every running app")

            ScreenRecordControl()

            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { state.resetAll() }
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold)).padding(5)
            }
            .buttonStyle(.plain)
            .help("Reset every app to its normal audio")
            .accessibilityLabel("Reset all apps")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Mixer tab

    private var mixerTab: some View {
        ScrollView {
            if displayApps.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 12)], spacing: 12) {
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
                    ForEach([0.2, 0.4, 0.6, 0.8], id: \.self) { fraction in
                        Circle().stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            .frame(width: geo.size.width * fraction, height: geo.size.width * fraction)
                    }
                    Path { p in
                        let w = geo.size.width, h = geo.size.height
                        p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                        p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                    }
                    .stroke(Color.primary.opacity(0.04), lineWidth: 1)

                    compassLabel("LOUDER", x: geo.size.width / 2, y: 12)
                    compassLabel("QUIETER", x: geo.size.width / 2, y: geo.size.height - 12)
                    compassLabel("L", x: 12, y: geo.size.height / 2)
                    compassLabel("R", x: geo.size.width - 12, y: geo.size.height / 2)

                    VStack(spacing: 2) {
                        Image(systemName: "headphones").font(.system(size: 14)).foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.08), in: Circle())
                            .overlay(Circle().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
                        Text("YOU").font(.system(size: 7, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .accessibilityHidden(true)

                    ForEach(displayApps.filter(\.isSpatialEnabled)) { app in
                        SpatialNodeView(app: app, canvasSize: geo.size, isSelected: selectedPID == app.id) {
                            withAnimation(.bouncy) { selectedPID = app.id }
                        }
                    }

                    if !displayApps.contains(where: \.isSpatialEnabled) {
                        Text("Add apps below, then drag them: up is louder, left and right pan the sound.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 260)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2 + 50)
                    }
                }
            }
            .padding(10)

            Divider().opacity(0.2)
            spatialTray
        }
    }

    private func compassLabel(_ text: String, x: CGFloat, y: CGFloat) -> some View {
        Text(text).font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
            .position(x: x, y: y)
            .accessibilityHidden(true)
    }

    private var spatialTray: some View {
        let available = displayApps.filter { !$0.isSpatialEnabled }
        return HStack {
            if available.isEmpty {
                Text("Every app is on the soundstage.")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("ADD").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                        ForEach(available) { app in
                            Button {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { state.toggleSpatial(for: app) }
                            } label: {
                                HStack(spacing: 5) {
                                    AppIconView(app: app, size: 18)
                                    Text(app.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                                    Image(systemName: "plus.circle.fill").font(.system(size: 9)).foregroundStyle(app.accentColor)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add \(app.name) to soundstage")
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

    private var inspector: some View {
        Group {
            if let app = selectedApp {
                ScrollView { inspectorContent(for: app) }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "hand.tap").font(.system(size: 20)).foregroundStyle(.secondary.opacity(0.5))
                    Text("Select an app").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                    Text("Pick a card or soundstage node to edit its channel.")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center).padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 260)
        .background(Color.primary.opacity(0.03))
    }

    private func inspectorContent(for app: AudioApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AppIconView(app: app, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 13, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(app.bundleID).font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1).textSelection(.enabled)
                }
            }

            Divider().opacity(0.2)

            section("OUTPUT", icon: "speaker.wave.2") {
                OutputDeviceMenu(app: app, showsFullName: true)
            }

            Divider().opacity(0.2)

            section("CHANNEL", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Volume").font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text("\(Int((app.volume * 100).rounded()))%")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(app.accentColor)
                    }
                    Slider(value: Binding(get: { app.volume }, set: { state.setVolume(for: app, to: $0) }), in: 0...1)
                        .tint(app.accentColor)
                        .accessibilityLabel("\(app.name) volume")
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Balance").font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text(balanceLabel(app.stereoPosition).capitalized)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(app.accentColor)
                    }
                    Slider(value: Binding(get: { app.stereoPosition }, set: { state.setStereoPosition(for: app, to: $0) }), in: -1...1)
                        .tint(app.accentColor)
                        .disabled(app.isSpatialEnabled)
                        .accessibilityLabel("\(app.name) balance")
                        .accessibilityValue(balanceLabel(app.stereoPosition))
                }
            }

            Divider().opacity(0.2)

            section("ACTIONS", icon: "bolt") {
                HStack(spacing: 6) {
                    actionButton(app.isMuted ? "Unmute" : "Mute", icon: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                 isActive: app.isMuted) { state.toggleMute(for: app) }
                    actionButton(app.isRecording ? "Stop" : "Record", icon: app.isRecording ? "stop.circle.fill" : "record.circle",
                                 isActive: app.isRecording) { state.toggleRecording(for: app) }
                }
                Button {
                    withAnimation(.bouncy(duration: 0.4)) { state.resetChannel(for: app) }
                } label: {
                    Label("Reset to Normal Audio", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Undo all changes and hand \(app.name)’s audio back to macOS")
            }

            Divider().opacity(0.2)

            section("SPATIAL", icon: "circle.hexagongrid") {
                Toggle(isOn: Binding(get: { app.isSpatialEnabled },
                                     set: { _ in withAnimation(.bouncy(duration: 0.4)) { state.toggleSpatial(for: app) } })) {
                    Text("Place on soundstage").font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(.switch)
                .tint(app.accentColor)
                Text("Drag the app in the Spatial tab to set its volume and balance by position.")
                    .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.circle").font(.system(size: 30)).foregroundStyle(.secondary.opacity(0.4))
            Text(state.showAllApps ? "No running apps" : "No apps using audio yet")
                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text("Start playing audio in an app and it’ll appear here.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(40)
    }

    // MARK: - Helpers

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

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
}

// MARK: - Visual effect

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
