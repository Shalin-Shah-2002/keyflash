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

        var didDetectMidSession = false

        let pty = PTYSpawn()
        let (exitCode, detected) = pty.run(
            command: commandArgs,
            // Always log debug decisions to /tmp/keyflash.log so we can diagnose
            // prompt detection without recompiling with --debug.
            debug: true,
            onTaskComplete: { _ in
                guard config.enabled else { return }
                didDetectMidSession = true
                writeLog("keyflash-run: mid-session task complete — notifying menu bar app (agent=\(agentName))")
                // Notify menu bar app → triggers continuous backlight flicker
                // (mac-brightnessctl -f 99999) until user presses a key/clicks.
                notifyMenuBarApp(agent: agentName)
            }
        )

        writeLog("keyflash-run: agent=\(agentName) exitCode=\(exitCode) detected=\(detected)")

        guard config.enabled else {
            writeLog("keyflash-run: config.enabled=false, skipping notification")
            if exitCode != 0 { Darwin.exit(exitCode) }
            return
        }

        // If the prompt detector never fired during the session (e.g. very short
        // command that exited immediately), still notify on exit so the backlight
        // flashes at least once.
        if !didDetectMidSession {
            writeLog("keyflash-run: no mid-session detection — sending exit notification to menu bar app")
            notifyMenuBarApp(agent: agentName)
        }

        writeLog("keyflash-run: done")

        if exitCode != 0 {
            Darwin.exit(exitCode)
        }
    }
}
