import SwiftUI
import KeyflashCore

/// The settings panel for keyflash — Liquid Glass surface with orange accents.
///
/// Accessible from the menu bar icon → "Settings…"
struct SettingsWindow: View {
    @AppStorage("backlightEnabled") private var backlightEnabled = true
    @AppStorage("pulseBrightness") private var pulseBrightness: Double = 255
    @AppStorage("pulseRampUpMs") private var pulseRampUpMs: Double = 150
    @AppStorage("pulseRampDownMs") private var pulseRampDownMs: Double = 150
    @AppStorage("launchAtLogin") private var launchAtLogin = false

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
                        Toggle("Enable Backlight Pulse", isOn: $backlightEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: Color.keyflashOrange))

                        VStack(alignment: .leading) {
                            sliderRow("Brightness", value: $pulseBrightness, range: 1...255, suffix: "")
                            sliderRow("Ramp Up", value: $pulseRampUpMs, range: 50...500, suffix: "ms")
                            sliderRow("Ramp Down", value: $pulseRampDownMs, range: 50...500, suffix: "ms")
                        }
                        .padding(.leading, 4)
                    }

                    // General
                    settingsSection("General") {
                        Toggle("Launch at Login", isOn: $launchAtLogin)
                            .toggleStyle(SwitchToggleStyle(tint: Color.keyflashOrange))
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

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
                .tint(Color.keyflashOrange)
            Text("\(Int(value.wrappedValue))\(suffix)")
                .font(.caption.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    SettingsWindow()
}
