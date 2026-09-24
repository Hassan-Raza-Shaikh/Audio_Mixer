import SwiftUI

/// Content of the menu-bar extra: a compact mixer plus the screen recorder.
struct MenuBarDropdownView: View {
    @ObservedObject var state = AppState.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var displayApps: [AudioApp] { state.visibleApps }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            VStack(spacing: 8) {
                if state.audioAccessLikelyDenied { AudioAccessBanner() }
                if let notice = state.notice { NoticeBanner(notice: notice) }
            }
            .padding(.horizontal, 12)
            .padding(.top, state.audioAccessLikelyDenied || state.notice != nil ? 10 : 0)
            .animation(.easeOut(duration: 0.2), value: state.notice)

            filterBar

            if displayApps.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(displayApps) { app in appRow(app) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.4)
            ScreenRecordControl(wide: true)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            footer
        }
        .frame(width: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Aura").font(.system(size: 14, weight: .bold, design: .rounded))
            Spacer()
            if let current = state.defaultDevice {
                Menu {
                    Picker("System Output", selection: Binding(
                        get: { current.id },
                        set: { uid in if let d = state.devices.first(where: { $0.id == uid }) { state.setSystemOutput(d) } }
                    )) {
                        ForEach(state.devices) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: deviceSymbol(for: current.name)).font(.system(size: 9))
                        Text(current.shortName).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("System output device")
                .accessibilityLabel("System output: \(current.name)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Filter

    private var filterBar: some View {
        HStack {
            Picker("Show", selection: $state.showAllApps) {
                Text("Audio Apps").tag(false)
                Text("All Apps").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { state.resetAll() }
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reset every app to its normal audio")
            .accessibilityLabel("Reset all apps")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Row

    private func appRow(_ app: AudioApp) -> some View {
        HStack(spacing: 10) {
            AppIconView(app: app, size: 34)
                .overlay(alignment: .bottomTrailing) {
                    if app.isPlaying {
                        PlayingIndicator(isPlaying: true, color: app.accentColor)
                            .padding(2)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .offset(x: 4, y: 4)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    if app.isRecording {
                        Image(systemName: "record.circle.fill").font(.system(size: 9)).foregroundStyle(.red)
                            .accessibilityLabel("Recording")
                    }
                    Spacer(minLength: 4)
                    OutputDeviceMenu(app: app)
                }
                HStack(spacing: 8) {
                    VolumeSlider(app: app)
                    Text("\(Int((app.volume * 100).rounded()))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                        .accessibilityHidden(true)
                    CircleIconButton(systemImage: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                     label: app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)",
                                     isActive: app.isMuted, size: 22) {
                        withAnimation(.bouncy(duration: 0.3)) { state.toggleMute(for: app) }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button(app.isRecording ? "Stop Recording \(app.name)" : "Record \(app.name)’s Audio") { state.toggleRecording(for: app) }
            Button("Reset \(app.name)") { state.resetChannel(for: app) }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.circle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary.opacity(0.4))
            Text(state.showAllApps ? "No running apps" : "No apps using audio yet")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            if !state.showAllApps {
                Text("Play something in Music, Spotify, a browser or a video app and it’ll appear here.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "mixer")
                NSApp.activate()
            } label: {
                Label("Open Mixer", systemImage: "square.grid.2x2")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            Spacer()

            CircleIconButton(systemImage: "gearshape", label: "Settings", size: 26) {
                openSettings()
                NSApp.activate()
            }
            CircleIconButton(systemImage: "power", label: "Quit Aura", isActive: true, size: 26) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
