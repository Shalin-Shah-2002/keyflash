import Cocoa
import KeyflashCore

/// Singleton config store backed by the YAML file at ~/.config/keyflash/config.yaml.
///
/// The config types and loader live in KeyflashCore so the app and
/// keyflash-run always read the same file the same way.
public class ConfigStore {
    public static let shared = ConfigStore()

    public var config: KeyflashConfig

    private let configFile: URL

    private init() {
        configFile = KeyflashPaths.configFile

        if FileManager.default.fileExists(atPath: configFile.path) {
            config = ConfigLoader.load()
        } else {
            config = KeyflashConfig()
            save()
        }
    }

    /// Re-reads the file (it may have been edited by hand) before a change, and
    /// keeps any keys keyflash doesn't know about.
    public func update(_ change: (inout KeyflashConfig) -> Void) {
        do {
            config = try ConfigLoader.update(change)
        } catch {
            log("ConfigStore: failed to save config: \(error.localizedDescription)")
        }
    }

    public func save() {
        do {
            try ConfigLoader.save(config)
        } catch {
            log("ConfigStore: failed to save config: \(error.localizedDescription)")
        }
    }
}
