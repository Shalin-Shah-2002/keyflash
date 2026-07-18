import Foundation
import ServiceManagement

/// Manages auto-start of the keyflash menu bar app at login.
///
/// Uses `SMAppService` (macOS 13+) for modern LaunchAgent registration,
/// falling back to manual plist creation for older systems.
public struct LaunchAgentManager {
    /// Whether the launch agent is currently registered.
    public static var isRegistered: Bool {
        if #available(macOS 13, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            let laDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents")
            let plistPath = laDir.appendingPathComponent(launchAgentPlist)
            return FileManager.default.fileExists(atPath: plistPath.path)
        }
    }

    /// Register the app as a LaunchAgent to auto-start at login.
    public static func register() {
        if #available(macOS 13, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                print("[keyflash] SMAppService registration failed: \(error)")
                fallbackRegister()
            }
        } else {
            fallbackRegister()
        }
    }

    /// Unregister the LaunchAgent.
    public static func unregister() {
        if #available(macOS 13, *) {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                print("[keyflash] SMAppService unregistration failed: \(error)")
                fallbackUnregister()
            }
        } else {
            fallbackUnregister()
        }
    }

    // MARK: - Fallback for older macOS (< 13)

    private static let launchAgentPlist = "com.keyflash.keyflash.plist"

    private static func fallbackRegister() {
        let laDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = laDir.appendingPathComponent(launchAgentPlist)

        let plist: [String: Any] = [
            "Label": "com.keyflash.keyflash",
            "ProgramArguments": [Bundle.main.executablePath ?? "/usr/local/bin/keyflash"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "InterActive",
        ]

        try? FileManager.default.createDirectory(at: laDir, withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistPath)

            // Load with launchctl
            let task = Process()
            task.launchPath = "/bin/launchctl"
            task.arguments = ["load", plistPath.path]
            try? task.run()
            task.waitUntilExit()
        }
    }

    private static func fallbackUnregister() {
        let laDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = laDir.appendingPathComponent(launchAgentPlist)

        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["unload", plistPath.path]
        try? task.run()
        task.waitUntilExit()

        try? FileManager.default.removeItem(at: plistPath)
    }
}
