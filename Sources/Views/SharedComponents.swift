import SwiftUI

// MARK: - Device Symbols

/// Single source of truth for mapping an output-device name to an SF Symbol.
/// (Previously duplicated three times across the views.)
func deviceSymbol(for name: String) -> String {
    let n = name.lowercased()
    if n.contains("airpod") { return "airpods.pro" }
    if n.contains("headphone") || n.contains("beats") { return "headphones" }
    if n.contains("hdmi") || n.contains("display") || n.contains("tv") { return "display" }
    if n.contains("blackhole") || n.contains("loopback") || n.contains("aggregate") { return "arrow.triangle.2.circlepath" }
    if n.contains("speaker") || n.contains("macbook") || n.contains("imac") || n.contains("built-in") { return "hifispeaker.fill" }
    return "speaker.wave.2.fill"
}

// MARK: - Live Level Meter

/// Compact level meter driven by the real peak amplitude coming from the
/// capture engine. Falls back to flat bars when the channel is idle.
struct LevelBars: View {
    let pid: Int32
    let color: Color
    var barCount: Int = 3

    var body: some View {
        TimelineView(.animation) { _ in
            let peak = Double(AudioCaptureEngine.shared.getPeak(for: pid))
            let level = min(1.0, peak * 2.5)
            Canvas { context, size in
                let gap: CGFloat = 1.5
                let barW = (size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
                // Weight bars so the middle is tallest, giving an EQ-like shape.
                let weights: [Double] = [0.7, 1.0, 0.8, 0.6, 0.9]
                for i in 0..<barCount {
                    let h = max(1.5, size.height * CGFloat(level * weights[i % weights.count]))
                    let x = CGFloat(i) * (barW + gap)
                    let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(level > 0.02 ? 0.9 : 0.25)))
                }
            }
        }
    }
}

// MARK: - Volume Slider

/// The one volume slider used everywhere. Click-or-drag anywhere on the track
/// to set the level; the fill is the app's accent color and dims when muted.
struct VolumeSlider: View {
    let app: AudioApp
    @ObservedObject var state = AppState.shared
    @State private var isDragging = false
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let fillWidth = max(0, min(geo.size.width, geo.size.width * CGFloat(app.volume)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                Capsule()
                    .fill(app.isMuted ? AnyShapeStyle(Color.secondary.opacity(0.3))
                                      : AnyShapeStyle(app.accentColor.gradient))
                    .frame(width: fillWidth)

                Capsule()
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        state.setVolume(for: app, to: max(0, min(1, Double(g.location.x / geo.size.width))))
                    }
                    .onEnded { _ in isDragging = false }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: 6)
        .scaleEffect(y: isDragging ? 1.6 : (isHovering ? 1.3 : 1.0), anchor: .center)
        .animation(.easeOut(duration: 0.15), value: isDragging || isHovering)
    }
}

// MARK: - Screen Record Control

/// Toggles screen recording (with optional system audio) from anywhere in the
/// app. `wide` gives the full-width dropdown treatment; otherwise it's a
/// compact toolbar control.
struct ScreenRecordControl: View {
    @ObservedObject var recorder = ScreenRecorder.shared
    var wide = false
    @State private var pulse = false

    private var timeString: String {
        let t = Int(recorder.elapsed)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        if wide {
            HStack(spacing: 8) {
                recordButton
                    .frame(maxWidth: .infinity)
                if !recorder.isRecording { audioToggle }
            }
        } else {
            HStack(spacing: 6) {
                if recorder.isRecording {
                    Text(timeString)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.red)
                } else {
                    audioToggle
                }
                recordButton
            }
        }
    }

    private var recordButton: some View {
        Button(action: { recorder.toggle() }) {
            HStack(spacing: 6) {
                ZStack {
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 2).fill(.red).frame(width: 9, height: 9)
                    } else {
                        Circle().fill(.red).frame(width: 10, height: 10)
                            .opacity(pulse ? 0.55 : 1.0)
                    }
                }
                if wide {
                    Text(recorder.isRecording ? "Stop Recording  \(timeString)" : "Record Screen")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(recorder.isRecording ? .red : .primary)
                }
            }
            .padding(.horizontal, wide ? 12 : 8)
            .padding(.vertical, wide ? 7 : 5)
            .background(
                (recorder.isRecording ? Color.red.opacity(0.12) : Color.primary.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(recorder.isRecording ? "Stop and save to ~/Movies/Aura Screen Recordings" : "Record the screen to a .mov file")
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var audioToggle: some View {
        Button(action: { recorder.includeAudio.toggle() }) {
            Image(systemName: recorder.includeAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 10))
                .foregroundStyle(recorder.includeAudio ? Color.accentColor : .secondary)
                .frame(width: 24, height: 24)
                .background(recorder.includeAudio ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05), in: Circle())
        }
        .buttonStyle(.plain)
        .help(recorder.includeAudio ? "System audio will be included" : "Recording video only — click to include audio")
    }
}

// MARK: - Permission Banner

/// Shown when Aura can't capture app audio yet. The process-tap path needs
/// Audio Recording access (with Screen Recording as a fallback), so without a
/// grant nothing would work.
struct PermissionBanner: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Audio access needed")
                    .font(.system(size: 11, weight: .semibold))
                Text("Aura taps each app's audio to control its volume and routing. Nothing is recorded to disk unless you press Record.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Grant…") { state.requestCapturePermission() }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 0.5)
        )
    }
}
