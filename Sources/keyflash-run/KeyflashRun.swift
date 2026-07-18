import Foundation
import Darwin
import ArgumentParser
import KeyflashCore
import OSLog

// Debug logging to /tmp/keyflash.log
func writeLog(_ msg: String) {
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

/// The PTY-wrapper CLI for keyflash.
///
/// Spawns the agent command under a pseudo-terminal, forwards all I/O
/// transparently, and detects when the agent yields back to the user.
@main
struct KeyflashRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyflash-run",
        abstract: "Wrap a coding-agent CLI and pulse the keyboard backlight on task completion.",
        discussion: """
        Examples:
          keyflash-run -- claude code
          keyflash-run -- opencode
          keyflash-run --test-pulse
          keyflash-run --test-flash
        """,
        version: "0.1.0"
    )

    @Argument(help: "Command and arguments to wrap (e.g. \"claude code\")")
    var commandArgs: [String] = []

    @Flag(name: .long, help: "Test keyboard backlight pulse")
    var testPulse = false

    @Flag(name: .long, help: "Debug logging for prompt detection")
    var debug = false

    mutating func run() throws {
        if debug {
            setenv("KEYFLASH_DEBUG", "1", 1)
        }

        if testPulse {
            runTestPulse()
            return
        }

        guard !commandArgs.isEmpty else {
            throw ValidationError("Expected a command to run. Usage: keyflash-run -- <command>")
        }

        runPTY()
    }

    private func runTestPulse() {
        print("🔦 Testing keyboard backlight pulse...")
        guard let backlight = Backlight() else {
            print("⚠️  Could not access keyboard backlight. Try: sudo keyflash-run --test-pulse")
            Darwin.exit(1)
        }
        backlight.pulse()
        print("✅ Pulse complete")
    }

    private func runPTY() {
        var env = ProcessInfo.processInfo.environment
        env["KEYFLASH_ACTIVE"] = "1"

        let config = ConfigLoader.load()
        let agentName = URL(fileURLWithPath: commandArgs[0]).lastPathComponent

        // Track whether we already sent a mid-session notification
        var midSessionNotified = false

        let pty = PTYSpawn()
        let (exitCode, detected) = pty.run(
            command: commandArgs,
            environment: env,
            debug: debug,
            onTaskComplete: { agent in
                // Called when prompt detector sees task completion mid-session
                guard config.enabled, !midSessionNotified else { return }
                midSessionNotified = true
                writeLog("keyflash-run: mid-session task complete for agent=\(agentName)")
                NotifyClient.sendDone(agent: agentName, pid: Int(getpid()))
            }
        )

        writeLog("keyflash-run: agent=\(agentName) exitCode=\(exitCode) detected=\(detected)")

        if !config.enabled {
            writeLog("keyflash-run: config.enabled=false, skipping")
            if exitCode != 0 { Darwin.exit(exitCode) }
            return
        }

        // If prompt wasn't detected mid-session, notify on exit as fallback
        if !midSessionNotified {
            writeLog("keyflash-run: sending exit notification (no mid-session detection)")
            NotifyClient.sendDone(agent: agentName, pid: Int(getpid()))
        }

        writeLog("keyflash-run: done")

        if debug {
            print("[keyflash] Agent completed with exit code \(exitCode), detected: \(detected)")
        }

        if exitCode != 0 {
            Darwin.exit(exitCode)
        }
    }
}
