import SwiftUI

/// Liquid Glass theme with orange primary accent for keyflash.
///
/// Usage:
/// ```swift
/// someView
///     .foregroundColor(.kf.orange)
///     .background(.kf.liquidGlass)
///     .overlay(KFGlassOverlay())
/// ```
public struct KF {
    public init() {}
    // MARK: - Orange Accent Ramp
    public let orangeLight = Color(hex: "#FF7A1A")
    public let orange = Color(hex: "#FF8C2E")
    public let orangeDark = Color(hex: "#FF5E00")
    public let orangeDeep = Color(hex: "#E04D00")

    // MARK: - Gradients
    public let orangeGradient = LinearGradient(
        gradient: Gradient(colors: [Color(hex: "#FF9A3C"), Color(hex: "#FF5E00")]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public let orangeGlow = LinearGradient(
        gradient: Gradient(colors: [
            Color(hex: "#FF9A3C").opacity(0.6),
            Color(hex: "#FF5E00").opacity(0.2),
            Color.clear,
        ]),
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Liquid Glass Surfaces
    public let glassBackground = Color(hex: "#1C1C1E").opacity(0.72)
    public let glassBorder = Color(hex: "#FFFFFF").opacity(0.12)
    public let glassHighlight = Color(hex: "#FFFFFF").opacity(0.08)

    // MARK: - Icon Colors
    public let iconIdle = Color(hex: "#888888")
    public let iconActive = Color(hex: "#FF9A3C")
}

public extension Color {
    static let kf = KF()
    // Convenience: the default keyflash orange
    static let keyflashOrange = KF().orange

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - View Modifiers

/// A Liquid Glass background: translucent, vibrancy-blurred surface.
public struct KFGlassBackground: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.kf.glassBorder, lineWidth: 1)
            )
    }
}

/// A top-edge specular highlight for Liquid Glass depth.
public struct KFGlassHighlight: View {
    public var body: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color.kf.glassHighlight,
                Color.clear,
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 1)
    }
}

public extension View {
    func kfGlass() -> some View {
        modifier(KFGlassBackground())
    }

    func kfOrangeAccent() -> some View {
        foregroundStyle(KF().orangeGradient)
    }
}
