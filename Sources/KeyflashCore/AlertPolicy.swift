import Foundation

/// Why keyflash is being asked to alert.
public enum AlertEvent: String, CaseIterable {
    /// The agent finished its task.
    case done
    /// The agent is blocked waiting for you (permission prompt, question).
    case attention
    /// The agent hit an error.
    case error

    /// Parses the wire value; anything missing or unknown is `.done`, so old
    /// hooks (which send no event) keep working.
    public init(wire value: String?) {
        self = value.flatMap(AlertEvent.init(rawValue:)) ?? .done
    }

    /// A running flash is only replaced by a higher-priority event, so a
    /// pending "needs you" is never downgraded by a later "done".
    public var priority: Int {
        switch self {
        case .done: return 1
        case .attention: return 2
        case .error: return 3
        }
    }

    public var pattern: FlashPattern {
        switch self {
        case .done: return FlashPattern(interval: 0.5, fadeMs: 300)       // slow, steady pulse
        case .attention: return FlashPattern(interval: 0.15, fadeMs: 80)  // fast, urgent blink
        case .error: return FlashPattern(interval: 0.08, fadeMs: 40)      // rapid strobe
        }
    }
}

/// On/off timing for `mac-brightnessctl -f`.
public struct FlashPattern: Equatable {
    /// Seconds spent off, and on, in each cycle.
    public let interval: Double
    /// Fade time in milliseconds.
    public let fadeMs: Int

    public init(interval: Double, fadeMs: Int) {
        self.interval = interval
        self.fadeMs = fadeMs
    }
}

/// Decides whether an alert should be shown at all.
public enum AlertPolicy {
    public enum Decision: Equatable {
        case flash
        case suppressed(reason: String)

        public var shouldFlash: Bool { self == .flash }
    }

    /// How recently you must have used the keyboard or mouse to count as
    /// "watching". Events that need you use half the window, since a blocked
    /// agent matters more than a finished one.
    public static func quietWindow(for event: AlertEvent, config: KeyflashConfig) -> TimeInterval {
        let base = TimeInterval(config.watchingIdleSeconds)
        return event == .done ? base : base / 2
    }

    /// Stay quiet only when you're clearly already looking at the agent: a
    /// terminal or editor is the frontmost app *and* you were active recently.
    public static func evaluate(event: AlertEvent,
                                config: KeyflashConfig,
                                frontmostBundleID: String?,
                                idleSeconds: TimeInterval) -> Decision {
        guard config.suppressWhenWatching else { return .flash }
        guard let front = frontmostBundleID,
              matches(front, in: config.terminalBundleIds) else { return .flash }

        let window = quietWindow(for: event, config: config)
        if idleSeconds < window {
            return .suppressed(reason: "watching \(front) (active \(String(format: "%.1f", idleSeconds))s ago, window \(Int(window))s)")
        }
        return .flash
    }

    /// Case-insensitive match; an entry ending in `*` matches by prefix
    /// (e.g. `com.jetbrains.*`).
    static func matches(_ bundleID: String, in patterns: [String]) -> Bool {
        let id = bundleID.lowercased()
        return patterns.contains { pattern in
            let p = pattern.lowercased()
            if p.hasSuffix("*") { return id.hasPrefix(String(p.dropLast())) }
            return id == p
        }
    }
}
