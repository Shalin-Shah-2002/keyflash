import SwiftUI
import KeyflashCore

/// The settings panel for keyflash — Liquid Glass surface with orange accents.
///
/// Accessible from the menu bar icon → "Settings…"
struct SettingsWindow: View {
    // Backed by ~/.config/keyflash/config.yaml (the file the app actually reads).
    @State private var backlightEnabled = ConfigLoader.load().backlightEnabled
    @State private var suppressWhenWatching = ConfigLoader.load().suppressWhenWatching
    @State private var watchingIdleSeconds = ConfigLoader.load().watchingIdleSeconds
    @State private var launchAtLogin = LaunchAgentManager.isRegistered
    @State private var hooksStatus = SettingsWindow.currentHooksStatus()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "keyboard")
                    .foregroundStyle(KF().orangeGradient)
                    .font(.title2)
                Text("keyflash")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()
                .overlay(Color.kf.glassBorder)

            ScrollView {
                VStack(spacing: 20) {
                    // Pulse Preview Card
                    PulsePreview()
                        .kfGlass()
                        .padding(.horizontal)

                    // Backlight Settings
                    settingsSection("Keyboard Backlight") {
                        Toggle("Flash when an agent finishes", isOn: $backlightEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: Color.keyflashOrange))
                            .onChange(of: backlightEnabled) { _, newValue in
                                ConfigStore.shared.update { $0.backlightEnabled = newValue }
                            }

                        Toggle("Stay quiet when I'm watching the terminal", isOn: $suppressWhenWatching)
                            .toggleStyle(SwitchToggleStyle(tint: Color.keyflashOrange))
                            .onChange(of: suppressWhenWatching) { _, newValue in
                                ConfigStore.shared.update { $0.suppressWhenWatching = newValue }
                            }

                        Stepper("Counts as watching if active within \(watchingIdleSeconds)s",
                                value: $watchingIdleSeconds, in: 2...120)
                            .font(.subheadline)
                            .disabled(!suppressWhenWatching)
                            .onChange(of: watchingIdleSeconds) { _, newValue in
                                ConfigStore.shared.update { $0.watchingIdleSeconds = newValue }
                            }

                        Text("A terminal or editor must also be the frontmost app. Apps are listed in terminalBundleIds in ~/.config/keyflash/config.yaml.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Agents
                    settingsSection("Agents") {
                        Text(hooksStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Install / Repair Agent Hooks") {
                            AgentHooks.installAll().forEach { log("Settings: \($0)") }
                            hooksStatus = SettingsWindow.currentHooksStatus()
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.keyflashOrange)
                    }

                    // General
                    settingsSection("General") {
                        Toggle("Launch at Login", isOn: $launchAtLogin)
                            .toggleStyle(SwitchToggleStyle(tint: Color.keyflashOrange))
                            .onChange(of: launchAtLogin) { _, newValue in
                                guard newValue != LaunchAgentManager.isRegistered else { return }
                                if newValue {
                                    LaunchAgentManager.register()
                                } else {
                                    LaunchAgentManager.unregister()
                                }
                                // Show the real state (registration can fail or need approval).
                                let actual = LaunchAgentManager.isRegistered
                                launchAgentSync(actual)
                            }
                    }
                }
                .padding(.vertical)
            }
        }
        .frame(width: 400, height: 500)
        .background(.background.opacity(0.85))
    }

    // MARK: - Helpers

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline.weight(.medium))
                .foregroundStyle(KF().orangeGradient)

            content()
                .padding(.leading, 4)

            Divider()
                .overlay(Color.kf.glassBorder)
        }
        .padding(.horizontal)
    }

    private func launchAgentSync(_ actual: Bool) {
        launchAtLogin = actual
        ConfigStore.shared.update { $0.launchAtLogin = actual }
    }

    private static func currentHooksStatus() -> String {
        func mark(_ agent: AgentHooks.Agent) -> String {
            AgentHooks.isInstalled(agent) ? "✓ installed" : "✗ not installed"
        }
        return "Claude Code: \(mark(.claude))    OpenCode: \(mark(.opencode))"
    }
}

#Preview {
    SettingsWindow()
}
