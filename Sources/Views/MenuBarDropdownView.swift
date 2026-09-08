import SwiftUI

// MARK: - Menu Bar Dropdown

public struct MenuBarDropdownView: View {
    @ObservedObject var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    public init() {}

    private var displayApps: [AudioApp] {
        state.showAllApps ? state.apps : state.visibleApps
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            if !state.hasCapturePermission {
                PermissionBanner()
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            filterBar

            if displayApps.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(displayApps) { app in
                            appRow(app)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
            }

            Divider().opacity(0.4)

            ScreenRecordControl(wide: true)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            footer
        }
        .frame(width: 360)
        .background(Color.clear)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Aura")
                .font(.system(size: 14, weight: .bold, design: .rounded))

            Spacer()

            if let dev = state.defaultDevice {
                Menu {
                    Text("System Output")
                    Divider()
                    ForEach(state.devices) { device in
                        Button {
                            AudioDeviceManager.shared.setDefaultOutputDevice(deviceID: device)
                            state.refreshDevices()
                        } label: {
                            Label(device.name, systemImage: device.isDefault ? "checkmark" : deviceSymbol(for: device.name))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: deviceSymbol(for: dev.name)).font(.system(size: 9))
                        Text(dev.shortName).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack {
            Picker("", selection: $state.showAllApps) {
                Text("Audio apps").tag(false)
                Text("All apps").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            Spacer()

            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { state.resetToDefaults() }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reset all volumes, mutes and routes")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - App Row

    @ViewBuilder
    private func appRow(_ app: AudioApp) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(app.accentColor.opacity(0.1))
                    .frame(width: 34, height: 34)
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app.fill").font(.system(size: 15)).foregroundStyle(app.accentColor)
                }
                if AudioCaptureEngine.shared.isCapturing(pid: app.pid) && !app.isMuted {
                    LevelBars(pid: app.pid, color: app.accentColor)
                        .frame(width: 12, height: 8)
                        .padding(2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Spacer()
                    devicePicker(for: app)
                }

                HStack(spacing: 8) {
                    VolumeSlider(app: app)

                    Text("\(Int(app.volume * 100))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)

                    Button {
                        withAnimation(.bouncy(duration: 0.3)) { state.toggleMute(for: app) }
                    } label: {
                        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(app.isMuted ? 0.1 : 0.05), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func devicePicker(for app: AudioApp) -> some View {
        Menu {
            ForEach(state.devices) { device in
                Button {
                    withAnimation(.bouncy) { state.setOutputDevice(for: app, to: device) }
                } label: {
                    Label(device.name, systemImage: app.outputDevice.id == device.id ? "checkmark" : deviceSymbol(for: device.name))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: deviceSymbol(for: app.outputDevice.name)).font(.system(size: 8))
                Text(app.outputDevice.shortName).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.circle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary.opacity(0.4))
            Text(state.showAllApps ? "No running apps" : "No audio apps running")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            if !state.showAllApps {
                Text("Playing something in Spotify, a browser, or a video app? It'll show up here.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "spatial-studio")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 10))
                    Text("Open Mixer").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.red.opacity(0.8))
                    .padding(6)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Quit Aura")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

#Preview { MenuBarDropdownView() }
