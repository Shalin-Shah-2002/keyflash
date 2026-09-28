import Cocoa
import KeyflashCore
import Yams

/// Singleton config store backed by the YAML file at ~/.config/keyflash/config.yaml.
///
/// The config types and loader live in KeyflashCore so the app and
/// keyflash-run always read the same file the same way.
public class ConfigStore {
    public static let shared = ConfigStore()

    public var config: KeyflashConfig

    private let configDir: URL
    private let configFile: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configDir = home.appendingPathComponent(".config/keyflash")
        configFile = configDir.appendingPathComponent("config.yaml")

        if FileManager.default.fileExists(atPath: configFile.path) {
            config = ConfigLoader.load()
        } else {
            config = KeyflashConfig()
            save()
        }
    }

    /// Re-reads the file (it may have been edited by hand) before a change.
    public func update(_ change: (inout KeyflashConfig) -> Void) {
        config = ConfigLoader.load()
        change(&config)
        save()
    }

    public func save() {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let yaml = try YAMLEncoder().encode(config)
            try yaml.write(to: configFile, atomically: true, encoding: .utf8)
        } catch {
            log("ConfigStore: failed to save config: \(error.localizedDescription)")
        }
    }
}
