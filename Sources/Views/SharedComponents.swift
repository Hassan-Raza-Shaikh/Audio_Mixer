import AppKit
import SwiftUI

// MARK: - Device symbols

/// Maps an output-device name to an SF Symbol.
func deviceSymbol(for name: String) -> String {
    let n = name.lowercased()
    if n.contains("airpod") { return "airpods" }
    if n.contains("headphone") || n.contains("beats") { return "headphones" }
    if n.contains("hdmi") || n.contains("display") || n.contains("tv") { return "tv" }
    if n.contains("blackhole") || n.contains("loopback") || n.contains("aggregate") || n.contains("multi-output") { return "arrow.triangle.branch" }
    if n.contains("speaker") || n.contains("macbook") || n.contains("imac") || n.contains("built-in") { return "hifispeaker.fill" }
    return "speaker.wave.2.fill"
}

// MARK: - App icon

struct AppIconView: View {
    let app: AudioApp
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(app.accentColor.opacity(0.12))
            if let icon = app.icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(size * 0.14)
            } else {
                Image(systemName: "app.fill").font(.system(size: size * 0.45)).foregroundStyle(app.accentColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Activity

/// Animated waveform while an app is producing sound. Cheap enough to show on
/// every row (no per-frame level polling).
struct PlayingIndicator: View {
    let isPlaying: Bool
    var color: Color = .accentColor

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(isPlaying ? color : Color.secondary.opacity(0.35))
            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            .accessibilityLabel(isPlaying ? "Playing" : "Silent")
    }
}

/// Live level meter for an app Aura is routing (what you actually hear).
struct LevelBars: View {
    let pid: pid_t
    let color: Color
    var barCount = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let level = Double(min(1, AudioRouter.shared.outputLevel(for: pid) * 2.5))
            Canvas { context, size in
                let gap: CGFloat = 1.5
                let barWidth = (size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
                let weights: [Double] = [0.7, 1.0, 0.85, 0.6, 0.9]
                for i in 0..<barCount {
                    let height = max(1.5, size.height * CGFloat(level * weights[i % weights.count]))
                    let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: size.height - height, width: barWidth, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                 with: .color(color.opacity(level > 0.02 ? 0.9 : 0.25)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Volume slider

/// The volume slider used everywhere: click or drag anywhere on the track.
/// Fully adjustable with VoiceOver and the arrow keys.
struct VolumeSlider: View {
    let app: AudioApp
    @ObservedObject var state = AppState.shared
    @State private var isDragging = false
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let fill = geo.size.width * CGFloat(app.volume)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(app.isMuted ? AnyShapeStyle(Color.secondary.opacity(0.3)) : AnyShapeStyle(app.accentColor.gradient))
                    .frame(width: max(0, min(geo.size.width, fill)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        state.setVolume(for: app, to: Double(g.location.x / max(geo.size.width, 1)))
                    }
                    .onEnded { _ in isDragging = false }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: 6)
        .scaleEffect(y: isDragging ? 1.6 : (isHovering ? 1.3 : 1), anchor: .center)
        .animation(.easeOut(duration: 0.15), value: isDragging || isHovering)
        .padding(.vertical, 6)          // larger hit target than the visible track
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel("\(app.name) volume")
        .accessibilityValue("\(Int((app.volume * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: state.setVolume(for: app, to: app.volume + 0.05)
            case .decrement: state.setVolume(for: app, to: app.volume - 0.05)
            @unknown default: break
            }
        }
    }
}

// MARK: - Output device menu

/// Per-app output picker. "System Default" follows whatever macOS is using,
/// including when you plug in or unplug headphones.
struct OutputDeviceMenu: View {
    let app: AudioApp
    var showsFullName = false
    @ObservedObject var state = AppState.shared

    private var selection: Binding<String> {
        Binding(get: { app.outputDeviceUID ?? "" },
                set: { state.setOutputDevice(for: app, uid: $0.isEmpty ? nil : $0) })
    }

    private var label: String {
        guard let device = state.effectiveOutput(for: app) else { return "No Output" }
        if app.outputDeviceUID == nil { return showsFullName ? "System Default (\(device.name))" : "Default" }
        return showsFullName ? device.name : device.shortName
    }

    var body: some View {
        Menu {
            Picker("Output", selection: selection) {
                Section {
                    Text("System Default").tag("")
                }
                Section {
                    ForEach(state.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: deviceSymbol(for: state.effectiveOutput(for: app)?.name ?? ""))
                    .font(.system(size: 9))
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1)
                if showsFullName { Spacer(minLength: 4) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !showsFullName, vertical: true)
        .accessibilityLabel("Output device for \(app.name)")
        .accessibilityValue(label)
        .help("Where \(app.name) plays")
    }
}

// MARK: - Round icon button

struct CircleIconButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    var activeColor: Color = .red
    var size: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46))
                .foregroundStyle(isActive ? activeColor : Color.primary.opacity(0.7))
                .frame(width: size, height: size)
                .background(isActive ? activeColor.opacity(0.14) : Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Screen record control

/// Starts/stops a screen recording with optional system audio. `wide` is the
/// full-width menu-bar layout; otherwise it's a compact toolbar control.
struct ScreenRecordControl: View {
    @ObservedObject var recorder = ScreenRecorder.shared
    @ObservedObject var location = RecordingLocation.screen
    var wide = false

    private var timeString: String {
        let t = Int(recorder.elapsed)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        HStack(spacing: wide ? 8 : 6) {
            if recorder.isRecording && !wide {
                Text(timeString)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Recording time \(timeString)")
            }
            if !recorder.isRecording {
                CircleIconButton(systemImage: "folder", label: "Save recordings to \(location.displayPath) — click to change",
                                 size: 24) {
                    location.choose(message: "Choose where Aura saves screen recordings")
                }
                CircleIconButton(systemImage: recorder.includeAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                 label: recorder.includeAudio ? "System audio will be included" : "Video only — click to include system audio",
                                 isActive: recorder.includeAudio, activeColor: .accentColor, size: 24) {
                    recorder.includeAudio.toggle()
                }
            }
            recordButton
                .frame(maxWidth: wide ? .infinity : nil)
        }
    }

    private var recordButton: some View {
        Button { recorder.toggle() } label: {
            HStack(spacing: 6) {
                Group {
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 2).fill(.red).frame(width: 9, height: 9)
                    } else if recorder.isStarting {
                        ProgressView().controlSize(.mini)
                    } else {
                        // Deliberately static: a repeatForever pulse here kept the
                        // whole view re-rendering every frame (~20% CPU at idle).
                        Circle().fill(.red).frame(width: 10, height: 10)
                    }
                }
                .frame(width: 12, height: 12)
                if wide {
                    Text(recorder.isRecording ? "Stop Recording  \(timeString)" : "Record Screen")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(recorder.isRecording ? .red : .primary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, wide ? 12 : 8)
            .padding(.vertical, wide ? 7 : 6)
            .background(recorder.isRecording ? Color.red.opacity(0.12) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.isStarting)
        .help(recorder.isRecording ? "Stop and save the recording" : "Record the screen\(recorder.includeAudio ? " with system audio" : "")")
        .accessibilityLabel(recorder.isRecording ? "Stop screen recording" : "Record screen")
    }
}

// MARK: - Banners

/// Shown when routed apps are playing but Aura hears only silence — almost
/// always because System Audio Recording access was denied.
struct AudioAccessBanner: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill").font(.system(size: 16)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Aura can't hear your apps").font(.system(size: 11, weight: .semibold))
                Text("Allow Aura under Privacy & Security › Screen & System Audio Recording (System Audio Recording Only is enough), then try again.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Settings") { ScreenRecorder.openScreenRecordingSettings() }
                    Button("Try Again") { state.retryRouting() }
                }
                .controlSize(.small)
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.25), lineWidth: 0.5))
    }
}

/// Transient message (saved files, errors).
struct NoticeBanner: View {
    let notice: AppState.Notice
    @ObservedObject var state = AppState.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.revealURL == nil ? "info.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.revealURL == nil ? Color.secondary : Color.green)
            Text(notice.text).font(.system(size: 10, weight: .medium)).lineLimit(2)
            Spacer(minLength: 4)
            if let url = notice.revealURL {
                Button("Show in Finder") {
                    // Resolve the sandbox container symlink so Finder opens the real folder.
                    NSWorkspace.shared.activateFileViewerSelecting([url.resolvingSymlinksInPath()])
                }
                    .controlSize(.small)
            }
            Button { state.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
