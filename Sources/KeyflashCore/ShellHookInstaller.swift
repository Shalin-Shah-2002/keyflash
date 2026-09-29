import Foundation

/// Installs a shell function so `aider` reports completion to keyflash.
///
/// aider has its own hook: `--notifications-command` runs a command whenever it
/// is ready for your input. The function just adds those two flags, so aider runs
/// exactly as before (no wrapper, no PTY). Claude Code and OpenCode use their own
/// hooks (`AgentHooks`). Installing removes any older keyflash block (including
/// earlier `claude`/`opencode` aliases and the old aider wrapper) from every rc file.
public enum ShellHookInstaller {
    /// The command aider runs (through a shell) when it wants your input.
    static func aiderNotifyCommand(runPath: String) -> String {
        "\(shellQuote(runPath)) --notify aider --event done"
    }

    static func makeHookTemplate(runPath: String) -> String {
        let command = shellQuote(aiderNotifyCommand(runPath: runPath))
        return """
# >>> keyflash >>>
# Auto-installed — flashes the keyboard backlight when aider is ready for input.
# (Claude Code and OpenCode use their own hooks.) To disable: remove this block.
if [ -x \(shellQuote(runPath)) ]; then
  function aider { command aider --notifications --notifications-command \(command) "$@"; }
fi
# <<< keyflash <<<
"""
    }

    static func makeFishTemplate(runPath: String) -> String {
        let command = fishQuote(aiderNotifyCommand(runPath: runPath))
        return """
# >>> keyflash >>>
# Auto-installed — flashes the keyboard backlight when aider is ready for input.
# (Claude Code and OpenCode use their own hooks.) To disable: remove this block.
if test -x \(fishQuote(runPath))
  function aider; command aider --notifications --notifications-command \(command) $argv; end
end
# <<< keyflash <<<
"""
    }

    /// Single-quotes a string for POSIX shells.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Single-quotes a string for fish (inside single quotes fish only escapes \\ and \').
    private static func fishQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Installs the hook into the current shell's rc file, removing keyflash
    /// blocks from every other rc file. Returns a human-readable status line.
    @discardableResult
    public static func installIfNeeded(shell: String? = nil, runPath: String = AgentHooks.defaultRunPath()) -> String {
        // Resolve symlinks so dotfiles-managed rc files stay symlinks.
        let target = detectRcFile(shell: shell).resolvingSymlinksInPath()
        for file in allRcFiles() where file.resolvingSymlinksInPath() != target {
            removeOldHook(from: file)
        }

        let isFish = target.path.hasSuffix("config.fish")
        let block = isFish ? makeFishTemplate(runPath: runPath) : makeHookTemplate(runPath: runPath)
        var existing = ""
        if FileManager.default.fileExists(atPath: target.path) {
            // Never treat an unreadable file as empty: we'd overwrite the user's rc file.
            guard let text = try? String(contentsOf: target, encoding: .utf8) else {
                return "Shell hook FAILED → \(target.path): not readable as UTF-8; left untouched"
            }
            existing = text
        }
        var content = stripHook(existing)
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        if !content.isEmpty { content += "\n" }
        content += block + "\n"

        if content == existing {
            return "Shell hook already up to date → \(target.path)"
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try writePreservingMode(Data(content.utf8), to: target)
            return "Shell hook installed → \(target.path)"
        } catch {
            return "Shell hook FAILED → \(target.path): \(error.localizedDescription)"
        }
    }

    /// Re-points an already-installed hook at the current `keyflash-run` (e.g.
    /// after the app moved). Never adds a hook where there isn't one, and edits
    /// the block in place, wherever it lives. Returns the files it changed.
    @discardableResult
    public static func refreshInstalled(runPath: String = AgentHooks.defaultRunPath()) -> [String] {
        guard FileManager.default.isExecutableFile(atPath: runPath) else { return [] }
        var changed: [String] = []
        for link in allRcFiles() {
            let file = link.resolvingSymlinksInPath()
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  text.contains("# >>> keyflash >>>") else { continue }
            let block = file.path.hasSuffix("config.fish") ? makeFishTemplate(runPath: runPath) : makeHookTemplate(runPath: runPath)
            let updated = text.replacingOccurrences(
                of: "(?ms)^# >>> keyflash >>>.*?^# <<< keyflash <<<[^\\n]*(\\n|\\z)",
                with: NSRegularExpression.escapedTemplate(for: block + "\n"),
                options: .regularExpression)
            if updated != text, (try? writePreservingMode(Data(updated.utf8), to: file)) != nil {
                changed.append(file.path)
            }
        }
        return changed
    }

    /// True if any rc file has a keyflash block.
    public static var isInstalled: Bool {
        allRcFiles().contains {
            ((try? String(contentsOf: $0.resolvingSymlinksInPath(), encoding: .utf8)) ?? "").contains("# >>> keyflash >>>")
        }
    }

    /// Removes the keyflash block from a file, leaving every other line intact.
    private static func removeOldHook(from link: URL) {
        let file = link.resolvingSymlinksInPath()
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let cleaned = stripHook(content)
        if cleaned != content {
            try? writePreservingMode(Data(cleaned.utf8), to: file)
        }
    }

    /// Removes whole lines from `# >>> keyflash >>>` through `# <<< keyflash <<<`
    /// (plus one blank line directly above, which the installer adds). Never
    /// joins the surrounding lines together.
    public static func stripHook(_ content: String) -> String {
        let pattern = "(?ms)(^\\n)?^# >>> keyflash >>>.*?^# <<< keyflash <<<[^\\n]*(\\n|\\z)"
        return content.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private static func allRcFiles() -> [URL] {
        let home = KeyflashPaths.home
        return [
            home.appendingPathComponent(".zshrc"),
            home.appendingPathComponent(".bashrc"),
            home.appendingPathComponent(".bash_profile"),
            home.appendingPathComponent(".config/fish/config.fish"),
        ]
    }

    private static func detectRcFile(shell: String?) -> URL {
        let home = KeyflashPaths.home
        let shell = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // macOS terminals start bash as a login shell, which reads .bash_profile.
        if shell.contains("bash") { return home.appendingPathComponent(".bash_profile") }
        if shell.contains("fish") { return home.appendingPathComponent(".config/fish/config.fish") }
        return home.appendingPathComponent(".zshrc")
    }

    public static func remove() {
        allRcFiles().forEach(removeOldHook(from:))
    }
}
