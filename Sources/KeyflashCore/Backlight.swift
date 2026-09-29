import Foundation

/// Controls the Mac keyboard backlight by shelling out to `mac-brightnessctl`.
///
/// `mac-brightnessctl` is a CLI tool that uses the private CoreBrightness
/// `KeyboardBrightnessClient` API to control keyboard backlight.
/// It's installed alongside keyflash and provides reliable brightness control.
public final class Backlight {
    public let binaryPath: String

    public init?() {
        // Find mac-brightnessctl in known locations
        var paths = [
            "/opt/homebrew/bin/mac-brightnessctl",
            "/usr/local/bin/mac-brightnessctl"
        ]
        
        // Check inside the running executable's folder first (e.g., keyflash.app/Contents/MacOS/)
        if let execPath = Bundle.main.executablePath {
            let execDir = (execPath as NSString).deletingLastPathComponent
            paths.insert("\(execDir)/mac-brightnessctl", at: 0)
        }
        
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
        return setLevel(val)
    }

    /// Set keyboard backlight brightness as a fraction (0.0–1.0). Blocks until applied.
    @discardableResult
    public func setLevel(_ level: Float) -> Bool {
        let clamped = max(0, min(level, 1))
        return run([String(format: "%.3f", clamped)])
    }

    /// Current keyboard backlight brightness (0.0–1.0), or nil if it can't be read.
    public func currentLevel() -> Float? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binaryPath)
        task.arguments = []
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            keyflashLog("Backlight: could not read brightness: \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        // Output: "Current brightness: 0.42"
        let text = String(decoding: data, as: UTF8.self)
        guard let valuePart = text.split(separator: ":").last,
              let value = Float(valuePart.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value >= 0, value <= 1 else {
            return nil
        }
        return value
    }

    /// Quick pulse: ON briefly, then OFF (restores original brightness).
    public func pulse() {
        // Use flash for a brief visible pulse
        _ = run(["-f", "2", "0.15", "100"])
    }

    /// Arguments that make `mac-brightnessctl` flash on/off for about `duration`
    /// seconds (it restores the brightness it saw at start when it finishes).
    public static func flashArguments(duration: TimeInterval, interval: Double = 0.4, fadeMs: Int = 200) -> [String] {
        let interval = max(interval, 0.02)
        let cycles = max(1, Int(min(duration, 24 * 3600) / (2 * interval)))
        return ["-f", "\(cycles)", "\(interval)", "\(max(fadeMs, 0))"]
    }

    /// Flash arguments for an alert pattern (see `AlertEvent.pattern`).
    public static func flashArguments(duration: TimeInterval, pattern: FlashPattern) -> [String] {
        flashArguments(duration: duration, interval: pattern.interval, fadeMs: pattern.fadeMs)
    }

    // MARK: - Private

    @discardableResult
    private func run(_ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binaryPath)
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
