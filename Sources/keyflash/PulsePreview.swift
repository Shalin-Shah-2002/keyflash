import SwiftUI
import KeyflashCore

/// An animated preview of the keyboard backlight pulse, shown in settings.
///
/// Uses a Liquid Glass card with an animated orange gradient bar that
/// ramps up and down to simulate the backlight pulse.
struct PulsePreview: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 12) {
            // Pulse bar
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.kf.glassBackground)
                    .frame(height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.kf.glassBorder, lineWidth: 1)
                    )

                // Animated fill
                RoundedRectangle(cornerRadius: 6)
                    .fill(KF().orangeGradient)
                    .frame(width: isAnimating ? 280 : 4, height: 20)
                    .shadow(color: Color.keyflashOrange.opacity(0.4), radius: 4, x: 0, y: 0)
            }

            // Label + Test button
            HStack {
                Image(systemName: "keyboard")
                    .foregroundStyle(KF().orangeGradient)
                Text("Keyboard Backlight")
                    .font(.subheadline)
                Spacer()
                Button("Test") {
                    triggerPulse()
                }
                .buttonStyle(.bordered)
                .tint(Color.keyflashOrange)
                .controlSize(.small)
            }
        }
        .padding(16)
    }

    private func triggerPulse() {
        // Animate the preview bar like a real pulse
        withAnimation(.easeInOut(duration: 0.15)) {
            isAnimating = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.15)) {
                isAnimating = false
            }
        }

        // Also trigger the real backlight
        DispatchQueue.global(qos: .userInitiated).async {
            if let backlight = Backlight() {
                backlight.pulse()
            } else {
                keyflashLog("PulsePreview: could not open backlight device")
            }
        }
    }
}

#Preview {
    PulsePreview()
        .padding()
        .kfGlass()
}
