import Foundation

/// Installs a shell alias so `aider` is transparently wrapped by `keyflash-run`.
///
/// Claude Code and OpenCode are *not* aliased any more: they report task
/// completion exactly through `AgentHooks`, and running them under a PTY
/// wrapper only adds risk. Installing removes any old keyflash block
/// (including earlier `claude`/`opencode` aliases) from every rc file.
public enum ShellHookInstaller {
    private static func makeHookTemplate() -> String {
        let quoted = shellQuote(AgentHooks.defaultRunPath())
        return """
# >>> keyflash >>>
# Auto-installed — wraps aider for keyboard backlight notifications.
# (Claude Code and OpenCode use native hooks and need no wrapper.)
# To disable: remove this block entirely.
if [ -x \(quoted) ]; then
  function aider { \(quoted) -- aider "$@"; }
fi
# <<< keyflash <<<
"""
    }

    private static func makeFishTemplate() -> String {
        let runPath = AgentHooks.defaultRunPath()
        let quoted = "'" + runPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'") + "'"
        return """
# >>> keyflash >>>
# Auto-installed — wraps aider for keyboard backlight notifications.
# (Claude Code and OpenCode use native hooks and need no wrapper.)
if test -x \(quoted)
  function aider; \(quoted) -- aider $argv; end
end
# <<< keyflash <<<
"""
    }

    /// Single-quotes a string for POSIX shells.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Installs the hook into the current shell's rc file, removing keyflash
    /// blocks from every other rc file. Returns a human-readable status line.
    @discardableResult
    public static func installIfNeeded(shell: String? = nil) -> String {
        // Resolve symlinks so dotfiles-managed rc files stay symlinks.
        let target = detectRcFile(shell: shell).resolvingSymlinksInPath()
        for file in allRcFiles() where file.resolvingSymlinksInPath() != target {
            removeOldHook(from: file)
        }

        let isFish = target.path.hasSuffix("config.fish")
        let block = isFish ? makeFishTemplate() : makeHookTemplate()
        let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
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
            try content.write(to: target, atomically: true, encoding: .utf8)
            return "Shell hook installed → \(target.path)"
        } catch {
            return "Shell hook FAILED → \(target.path): \(error.localizedDescription)"
        }
    }

    /// Removes the keyflash block from a file, leaving every other line intact.
    private static func removeOldHook(from link: URL) {
        let file = link.resolvingSymlinksInPath()
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let cleaned = stripHook(content)
        if cleaned != content {
            try? cleaned.write(to: file, atomically: true, encoding: .utf8)
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
