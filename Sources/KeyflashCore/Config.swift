import Foundation
import Yams

/// User-facing configuration for keyflash.
public struct KeyflashConfig: Codable {
    public var enabled: Bool = true
    public var backlightEnabled: Bool = true
    public var pulseRampUpMs: Int = 150
    public var pulseRampDownMs: Int = 150
    public var pulseFps: Int = 30
    public var pulseBrightness: Int = 255
    public var launchAtLogin: Bool = false
    public var shouldAutoInstall: Bool = true
    public var debugMode: Bool = false

    /// Stay quiet when a terminal/editor is frontmost and you were recently active.
    public var suppressWhenWatching: Bool = true
    /// How recent your last key press / click must be to count as "watching".
    public var watchingIdleSeconds: Int = 10
    /// Play a system sound when the backlight can't be controlled (external
    /// keyboard, unsupported Mac, or the private API stops working).
    public var fallbackSound: Bool = true
    /// Apps that count as "the agent's terminal". Entries ending in `*` match by prefix.
    public var terminalBundleIds: [String] = KeyflashConfig.defaultTerminalBundleIds

    public static let defaultTerminalBundleIds: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",
        "com.jetbrains.*",
    ]

    public init() {}
}

/// Loads config from disk (used by both the app and the CLI)
public struct ConfigLoader {
    public static func load() -> KeyflashConfig {
        let configFile = KeyflashPaths.configFile

        guard let data = try? Data(contentsOf: configFile),
              let yaml = try? Yams.load(yaml: String(decoding: data, as: UTF8.self)),
              let dict = yaml as? [String: Any] else {
            return KeyflashConfig()
        }

        var config = KeyflashConfig()
        config.enabled = dict["enabled"] as? Bool ?? true
        config.backlightEnabled = dict["backlightEnabled"] as? Bool ?? true
        config.pulseRampUpMs = dict["pulseRampUpMs"] as? Int ?? 150
        config.pulseRampDownMs = dict["pulseRampDownMs"] as? Int ?? 150
        config.pulseFps = dict["pulseFps"] as? Int ?? 30
        config.pulseBrightness = dict["pulseBrightness"] as? Int ?? 255
        config.launchAtLogin = dict["launchAtLogin"] as? Bool ?? false
        config.shouldAutoInstall = dict["shouldAutoInstall"] as? Bool ?? true
        config.debugMode = dict["debugMode"] as? Bool ?? false
        config.fallbackSound = dict["fallbackSound"] as? Bool ?? true
        config.suppressWhenWatching = dict["suppressWhenWatching"] as? Bool ?? true
        config.watchingIdleSeconds = min(max(dict["watchingIdleSeconds"] as? Int ?? 10, 0), 3600)
        if let ids = dict["terminalBundleIds"] as? [Any] {
            config.terminalBundleIds = ids.compactMap { $0 as? String }
        }
        return config
    }
}

extension ConfigLoader {
    /// Loads the config, applies `change`, and saves it.
    @discardableResult
    public static func update(_ change: (inout KeyflashConfig) -> Void) throws -> KeyflashConfig {
        var config = load()
        change(&config)
        try save(config)
        return config
    }

    /// Writes `config` to disk. Keys the file already has that keyflash doesn't
    /// know about are kept (comments can't be, YAML parsing drops them).
    public static func save(_ config: KeyflashConfig) throws {
        let url = KeyflashPaths.configFile

        var merged: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any] {
            merged = existing
        }
        let fresh = try YAMLEncoder().encode(config)
        if let known = try Yams.load(yaml: fresh) as? [String: Any] {
            merged.merge(known) { _, new in new }
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePreservingMode(Data(try Yams.dump(object: merged, sortKeys: true).utf8), to: url)
    }
}
