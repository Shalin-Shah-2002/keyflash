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

/// Sends a task-done event to the menu bar app, which triggers the
/// highly-visible continuous backlight flicker (flashes until the user
/// presses a key or clicks the mouse).
///
/// This is the primary notification path. The direct Backlight.pulse() 2-flash
/// was too subtle — the menu bar's flickerUntilInteraction() is the real signal.
private func notifyMenuBarApp(agent: String) {
    writeLog("notifyMenuBarApp: sending taskDone for agent=\(agent)")
    NotifyClient.sendDone(agent: agent, pid: Int(ProcessInfo.processInfo.processIdentifier))
}

/// The PTY-wrapper CLI for keyflash.
///
/// Spawns the agent command under a pseudo-terminal, forwards all I/O
/// transparently, and notifies the keyflash menu bar app on task completion,
/// which then triggers the continuous keyboard backlight flicker.
@main
struct KeyflashRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyflash-run",
        abstract: "Wrap a coding-agent CLI and flash the keyboard backlight on task completion.",
        discussion: """
        Examples:
          keyflash-run -- claude
          keyflash-run -- opencode
          keyflash-run --test-pulse
        """,
        version: "0.1.0"
    )

    @Argument(help: "Command and arguments to wrap (e.g. \"claude\")")
    var commandArgs: [String] = []

    @Flag(name: .long, help: "Test keyboard backlight pulse")
    var testPulse = false

    @Flag(name: .long, help: "Debug logging for prompt detection")
    var debug = false

    mutating func run() throws {
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
            print("⚠️  Could not access keyboard backlight.")
            Darwin.exit(1)
        }
        backlight.pulse()
        print("✅ Pulse complete")
    }

    private func runPTY() {
        let config = ConfigLoader.load()
        let agentName = URL(fileURLWithPath: commandArgs[0]).lastPathComponent
        let pty = PTYSpawn()
        let (exitCode, detected) = pty.run(
            command: commandArgs,
            debug: true,
            onTaskComplete: { _ in
                guard config.enabled else { return }
                writeLog("keyflash-run: mid-session task complete — notifying menu bar app (agent=\(agentName))")
                notifyMenuBarApp(agent: agentName)
            }
        )

        writeLog("keyflash-run: agent=\(agentName) exitCode=\(exitCode) detected=\(detected)")

        guard config.enabled else {
            writeLog("keyflash-run: config.enabled=false, skipping notification")
            if exitCode != 0 { Darwin.exit(exitCode) }
            return
        }

        // Mid-session detection handles all notifications when Claude Code is waiting for prompt.
        // We do NOT send notification on process exit to avoid flashing when closing the app.

        writeLog("keyflash-run: done")

        if exitCode != 0 {
            Darwin.exit(exitCode)
        }
    }
}
