import SwiftUI
import KeyflashCore

/// The settings panel for keyflash — Liquid Glass surface with orange accents.
///
/// Accessible from the menu bar icon → "Settings…"
struct SettingsWindow: View {
    // Backed by ~/.config/keyflash/config.yaml (the file the app actually reads).
    @State private var backlightEnabled = ConfigLoader.load().backlightEnabled
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
                                if newValue {
                                    LaunchAgentManager.register()
                                } else {
                                    LaunchAgentManager.unregister()
                                }
                                ConfigStore.shared.update { $0.launchAtLogin = newValue }
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
