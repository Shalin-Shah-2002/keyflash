import Foundation
import OSLog

/// Shared debug logger for the KeyflashCore module (writes to /tmp/keyflash.log via POSIX).
public func keyflashLog(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)\n"
    os_log(.debug, "keyflash: %{public}s", msg)
    if let data = line.data(using: .utf8) {
        let fd = open("/tmp/keyflash.log", O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            data.withUnsafeBytes { buf in
                _ = write(fd, buf.baseAddress, buf.count)
            }
            close(fd)
        }
    }
}

/// Controls the Mac keyboard backlight by shelling out to `mac-brightnessctl`.
///
/// `mac-brightnessctl` is a CLI tool that uses the private CoreBrightness
/// `KeyboardBrightnessClient` API to control keyboard backlight.
/// It's installed alongside keyflash and provides reliable brightness control.
public final class Backlight {
    private let binaryPath: String

    public init?() {
        // Find mac-brightnessctl in known locations
        let paths = ["/opt/homebrew/bin/mac-brightnessctl",
                     "/usr/local/bin/mac-brightnessctl"]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            keyflashLog("Backlight: mac-brightnessctl not found")
            return nil
        }
        binaryPath = path
    }

    /// Set keyboard backlight brightness (0–255, mapped to 0.0–1.0 for the CLI).
    @discardableResult
    public func setBrightness(_ level: UInt16) -> Bool {
        let val = min(Float(level) / 255.0, 1.0)
        return run(["\(val)"])
    }

    /// Quick pulse: ON briefly, then OFF (restores original brightness).
    public func pulse() {
        // Use flash for a brief visible pulse
        _ = run(["-f", "2", "0.15", "100"])
    }

    /// Flash continuously until killed.
    public func flashContinuous() {
        let task = Process()
        task.launchPath = binaryPath
        task.arguments = ["-f", "99999", "0.4", "200"]
        try? task.run()
        // Don't wait — caller manages lifecycle
    }

    /// Stop any running mac-brightnessctl instance.
    public static func stopFlashing() {
        let task = Process()
        task.launchPath = "/usr/bin/pkill"
        task.arguments = ["-f", "mac-brightnessctl.*-f"]
        try? task.run()
    }

    // MARK: - Private

    @discardableResult
    private func run(_ args: [String]) -> Bool {
        let task = Process()
        task.launchPath = binaryPath
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let ok = task.terminationStatus == 0
            keyflashLog("Backlight: mac-brightnessctl \(args.joined(separator: " ")) -> \(ok ? "OK" : "FAIL(\(task.terminationStatus))")")
            return ok
        } catch {
            keyflashLog("Backlight: mac-brightnessctl error: \(error.localizedDescription)")
            return false
        }
    }
}
