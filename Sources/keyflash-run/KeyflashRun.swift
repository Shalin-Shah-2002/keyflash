import Foundation
import ArgumentParser
import KeyflashCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Sends a task-done event to the menu bar app, which triggers the
/// highly-visible continuous backlight flicker (flashes until the user
/// presses a key or clicks the mouse).
///
/// This is the primary notification path. The direct Backlight.pulse() 2-flash
/// was too subtle — the menu bar's flickerUntilInteraction() is the real signal.
private func notifyMenuBarApp(agent: String, event: AlertEvent = .done) {
    keyflashLog("notifyMenuBarApp: sending \(event.rawValue) for agent=\(agent)")
    NotifyClient.send(agent: agent, pid: Int(ProcessInfo.processInfo.processIdentifier), event: event)
}

/// The PTY-wrapper CLI for keyflash.
///
/// Spawns the agent command under a pseudo-terminal, forwards all I/O
/// transparently, and notifies the keyflash menu bar app on task completion,
/// which then triggers the continuous keyboard backlight flicker.
@main
struct KeyflashRun: ParsableCommand {
    /// PTY exec-helper mode (see `PTYSpawn.runExecHelper`) must be handled
    /// before argument parsing: everything after the marker is the command.
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == PTYSpawn.execHelperFlag {
            PTYSpawn.runExecHelper(Array(args.dropFirst(2)))
        }
        self.main(nil)
    }

    static let configuration = CommandConfiguration(
        commandName: "keyflash-run",
        abstract: "Wrap a coding-agent CLI and flash the keyboard backlight on task completion.",
        discussion: """
        Claude Code, OpenCode and aider report task completion themselves through
        hooks (installed by the menu bar app, or with --install-hooks), so none of
        them needs to be wrapped. `keyflash-run -- <command>` is a generic wrapper
        for other agents: it flashes when output goes quiet after you press Enter.

        Examples:
          keyflash-run --install-hooks
          keyflash-run --notify claude
          keyflash-run --notify claude --event attention
          keyflash-run -- some-other-agent
          keyflash-run --test-pulse
        """,
        version: "0.3.0"
    )

    @Argument(help: "Command and arguments to wrap (e.g. \"claude\")")
    var commandArgs: [String] = []

    @Flag(name: .long, help: "Test keyboard backlight pulse")
    var testPulse = false

    @Flag(name: .long, help: "Debug logging for prompt detection")
    var debug = false

    @Option(name: .long, help: "Tell the menu bar app that <agent> finished a task (used by agent hooks)")
    var notify: String?

    @Option(name: .long, help: "With --notify: done (default), attention (agent needs you) or error")
    var event: String?

    @Flag(name: .long, help: "Install the Claude Code, OpenCode and aider completion hooks")
    var installHooks = false

    @Flag(name: .long, help: "Remove the completion hooks (and stop the app from reinstalling them)")
    var uninstallHooks = false

    mutating func run() throws {
        if let agent = notify {
            var alert = AlertEvent.done
            if let raw = event {
                guard let parsed = AlertEvent(rawValue: raw) else {
                    throw ValidationError("Unknown --event '\(raw)'. Use: \(AlertEvent.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                alert = parsed
            }
            // Called from agent hooks: must be fast, silent and never fail the agent.
            notifyMenuBarApp(agent: agent.isEmpty ? "agent" : agent, event: alert)
            return
        }

        if installHooks {
            AgentHooks.installAll().forEach { print($0) }
            print(ShellHookInstaller.installIfNeeded())
            // Undo a previous --uninstall-hooks: let the app keep them up to date again.
            _ = try? ConfigLoader.update { $0.shouldAutoInstall = true }
            print("Restart running claude/opencode sessions, and open a new terminal for aider.")
            return
        }

        if uninstallHooks {
            AgentHooks.uninstallAll().forEach { print($0) }
            ShellHookInstaller.remove()
            print("Shell hook removed")
            // Otherwise the menu bar app would put them back on its next launch.
            _ = try? ConfigLoader.update { $0.shouldAutoInstall = false }
            print("Automatic reinstall is off (run --install-hooks to turn it back on).")
            return
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
            print("⚠️  Could not access keyboard backlight.")
            Foundation.exit(1)
        }
        backlight.pulse()
        print("✅ Pulse complete")
    }

    private func runPTY() {
        let config = ConfigLoader.load()
        let agentName = URL(fileURLWithPath: commandArgs[0]).lastPathComponent

        // Claude Code / OpenCode with keyflash hooks installed report completion
        // exactly; running the output-silence heuristic too would double-fire.
        let nativeAgent = AgentHooks.Agent(rawValue: agentName)
        let useHeuristic = nativeAgent.map { !AgentHooks.isInstalled($0) } ?? true
        if !useHeuristic {
            keyflashLog("keyflash-run: \(agentName) has native keyflash hooks — passthrough only")
        }

        var onTaskComplete: PTYSpawn.TaskCompleteCallback?
        if useHeuristic {
            onTaskComplete = { _ in
                guard config.enabled else { return }
                keyflashLog("keyflash-run: mid-session task complete — notifying menu bar app (agent=\(agentName))")
                notifyMenuBarApp(agent: agentName)
            }
        }

        let pty = PTYSpawn()
        let (exitCode, detected) = pty.run(
            command: commandArgs,
            execHelper: Bundle.main.executableURL?.resolvingSymlinksInPath().path,
            debug: debug || config.debugMode,
            onTaskComplete: onTaskComplete
        )

        keyflashLog("keyflash-run: agent=\(agentName) exitCode=\(exitCode) detected=\(detected)")

        // Mid-session detection handles all notifications while the agent waits for a prompt.
        // We do NOT send a notification on process exit to avoid flashing when closing the agent.

        if exitCode != 0 {
            Foundation.exit(exitCode)
        }
    }
}
