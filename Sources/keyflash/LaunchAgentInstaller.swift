import Foundation
import ServiceManagement

/// Manages auto-start of the keyflash menu bar app at login via `SMAppService`.
public enum LaunchAgentManager {
    /// Whether the app is registered as a login item.
    public static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register the app to auto-start at login.
    @discardableResult
    public static func register() -> Bool {
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            log("LaunchAgentManager: registration failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Remove the login item.
    @discardableResult
    public static func unregister() -> Bool {
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            log("LaunchAgentManager: unregistration failed: \(error.localizedDescription)")
            return false
        }
    }
}
