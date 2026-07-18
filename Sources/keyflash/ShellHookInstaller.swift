import Foundation

/// Installs shell aliases so `claude` and `opencode` are transparently
/// wrapped by `keyflash-run`.
public struct ShellHookInstaller {
    /// Generates the hook with the correct full path to keyflash-run.
    private static func makeHookTemplate() -> String {
        // Find keyflash-run relative to the running app
        let runPath: String
        if let executablePath = Bundle.main.executablePath {
            let dir = (executablePath as NSString).deletingLastPathComponent
            runPath = "\(dir)/keyflash-run"
        } else {
            // Fallback to /Applications
            runPath = "/Applications/keyflash.app/Contents/MacOS/keyflash-run"
        }

        return """
# >>> keyflash >>>
# Auto-installed — wraps coding agents for keyboard backlight notifications.
# To disable: comment out the lines below, or remove this block entirely.

alias claude='\(runPath) -- claude'
alias opencode='\(runPath) -- opencode'
alias aider='\(runPath) -- aider'
# <<< keyflash <<<
"""
    }

    /// Installs the hook. Idempotent: skips if already present with the same path.
    public static func installIfNeeded() {
        guard let rcPath = detectRcFile() else {
            print("[keyflash] Could not detect shell rc file.")
            return
        }
        let template = makeHookTemplate()

        // Remove old hook block if present (from any previous install)
        removeOldHook(from: rcPath)

        // Append new hook
        append(to: rcPath, content: template)
        print("[keyflash] Shell hook installed → \(rcPath.path)")
    }

    private static func removeOldHook(from file: URL) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let pattern = "(?s)\\n*# >>> keyflash >>>.*?# <<< keyflash <<<\\n*"
        let cleaned = content.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        try? cleaned.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func append(to file: URL, content: String) {
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = "\n\(content)\n".data(using: .utf8) {
                handle.write(data)
            }
        } else {
            try? "\(content)\n".write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func detectRcFile() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if shell.contains("zsh") { return home.appendingPathComponent(".zshrc") }
        if shell.contains("bash") { return home.appendingPathComponent(".bashrc") }
        if shell.contains("fish") { return home.appendingPathComponent(".config/fish/config.fish") }
        return home.appendingPathComponent(".zshrc")
    }

    public static func remove() {
        guard let rcPath = detectRcFile() else { return }
        removeOldHook(from: rcPath)
    }
}
