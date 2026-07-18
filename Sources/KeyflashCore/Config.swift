import Foundation
import IOKit
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

    public init() {}
}

/// Loads config from disk (used by both the app and the CLI)
public struct ConfigLoader {
    public static func load() -> KeyflashConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configFile = home.appendingPathComponent(".config/keyflash/config.yaml")

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
        return config
    }
}
