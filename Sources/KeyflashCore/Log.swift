import Foundation
#if canImport(Darwin)
import Darwin
import OSLog
#else
import Glibc
#endif

/// Per-user locations shared by the menu bar app and `keyflash-run`.
///
/// Nothing lives in the shared `/tmp` any more: another local user could
/// pre-create a symlink there (log) or squat the socket path.
public enum KeyflashPaths {
    /// Home directory used for *other tools'* config files (Claude Code,
    /// OpenCode, shell rc files). Follows `$HOME` exactly like those tools do.
    /// Overridable so tests can use a sandbox.
    public static var home: URL = {
        if let env = ProcessInfo.processInfo.environment["HOME"], env.hasPrefix("/") {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// Home directory for keyflash's own runtime files (socket, log, config).
    /// Taken from the account database, not `$HOME`, so the menu bar app
    /// (started by launchd) and `keyflash-run` (started from any shell or
    /// hook) always agree on the socket path. Overridable for tests.
    public static var runtimeHome: URL = FileManager.default.homeDirectoryForCurrentUser

    /// Base directory for runtime files (created with 0700 on first use).
    public static var supportDirectory: URL {
        runtimeHome.appendingPathComponent("Library/Application Support/keyflash", isDirectory: true)
    }

    public static var logFile: URL {
        runtimeHome.appendingPathComponent("Library/Logs/keyflash.log")
    }

    public static var configFile: URL {
        runtimeHome.appendingPathComponent(".config/keyflash/config.yaml")
    }

    /// Unix socket the menu bar app listens on. Falls back to a per-uid path in
    /// /tmp only if the home-based path would exceed `sun_path` (104 bytes).
    public static var socketPath: String {
        let preferred = supportDirectory.appendingPathComponent("keyflash.sock").path
        if preferred.utf8.count < 100 { return preferred }
        return "/tmp/keyflash-\(getuid()).sock"
    }

    /// Creates the directory holding the socket, private to the current user.
    public static func ensureSocketDirectory() {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

/// Log file is rotated to `keyflash.log.1` once it grows past this size.
private let maxLogBytes: off_t = 1_000_000

/// Shared debug logger: unified logging plus ~/Library/Logs/keyflash.log.
public func keyflashLog(_ msg: String) {
    #if canImport(Darwin)
    os_log(.debug, "keyflash: %{public}s", msg)
    #endif

    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)\n"
    let path = KeyflashPaths.logFile.path

    var st = stat()
    if lstat(path, &st) == 0 && st.st_size > maxLogBytes {
        _ = rename(path, path + ".1")
    } else if lstat(path, &st) != 0 {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
    }

    // O_NOFOLLOW: never write through a symlink planted at the log path.
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    let bytes = Array(line.utf8)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}
