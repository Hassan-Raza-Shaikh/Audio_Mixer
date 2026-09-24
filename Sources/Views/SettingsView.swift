import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var screenFolder = RecordingLocation.screen
    @ObservedObject private var audioFolder = RecordingLocation.audio
    @ObservedObject private var recorder = ScreenRecorder.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Aura at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if loginItemNeedsApproval {
                    HStack {
                        Text("Allow Aura in Login Items to finish turning this on.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
            }

            Section("Screen Recording") {
                Toggle("Include system audio", isOn: $recorder.includeAudio)
                folderRow("Save to", location: screenFolder, message: "Choose where Aura saves screen recordings")
            }

            Section("App Audio Recording") {
                folderRow("Save to", location: audioFolder, message: "Choose where Aura saves app audio recordings")
            }

            Section {
                LabeledContent("Screen & System Audio Recording") {
                    Button("Open Privacy Settings") { ScreenRecorder.openScreenRecordingSettings() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Aura asks for System Audio Recording the first time you adjust an app, and for Screen Recording the first time you record the screen. Audio is processed on this Mac and never leaves it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionString)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func folderRow(_ title: String, location: RecordingLocation, message: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(location.displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(location.displayPath)
                Button("Choose…") { location.choose(message: message) }
                    .controlSize(.small)
                if !location.isDefault {
                    Button("Reset") { location.resetToDefault() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // Also reached when we correct the toggle below; nothing to do then.
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppState.shared.showNotice("Couldn't update the login item: \(error.localizedDescription)")
        }
        let status = SMAppService.mainApp.status
        loginItemNeedsApproval = status == .requiresApproval
        if (status == .enabled) != launchAtLogin { launchAtLogin = status == .enabled }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
