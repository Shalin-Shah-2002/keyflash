import Foundation

/// Installs completion hooks into the coding agents themselves, so they tell
/// keyflash *exactly* when a task finishes instead of keyflash guessing from
/// terminal output.
///
/// - Claude Code: `Stop` hook (turn finished) and `Notification` hook for
///   permission prompts / MCP input requests, in `~/.claude/settings.json`.
/// - OpenCode: a global plugin at `~/.config/opencode/plugins/keyflash.js`
///   that reacts to `session.idle` (main sessions only), `permission.asked`
///   and `question.asked`.
///
/// Every hook runs `keyflash-run --notify <agent> --event <done|attention|error>`, which pokes the menu bar
/// app over its Unix socket.
public enum AgentHooks {
    /// Substring used to recognise hook entries that keyflash owns.
    static let marker = "keyflash-run"

    public enum Agent: String, CaseIterable {
        case claude
        case opencode
    }

    public struct InstallError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: - Paths

    static var home: URL { KeyflashPaths.home }

    static var claudeSettingsURL: URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    /// Where OpenCode may look for config: `~/.config/opencode`, plus
    /// `$XDG_CONFIG_HOME/opencode` when that is set to something else. The menu bar
    /// app (started by macOS) doesn't see the XDG variable your shell has, so
    /// installing to both covers either way OpenCode was launched.
    static var opencodeConfigDirs: [URL] {
        var dirs = [home.appendingPathComponent(".config/opencode")]
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            let dir = URL(fileURLWithPath: xdg).appendingPathComponent("opencode")
            if dir.path != dirs[0].path { dirs.append(dir) }
        }
        return dirs
    }

    static var opencodePluginURLs: [URL] {
        opencodeConfigDirs.map { $0.appendingPathComponent("plugins/keyflash.js") }
    }

    /// Older OpenCode releases used the singular `plugin/` directory. Current
    /// releases load both, so a copy there would fire twice.
    static var legacyOpencodePluginURLs: [URL] {
        opencodeConfigDirs.map { $0.appendingPathComponent("plugin/keyflash.js") }
    }

    /// Path of the `keyflash-run` binary that ships next to the running executable
    /// (inside `keyflash.app/Contents/MacOS/`).
    public static func defaultRunPath() -> String {
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            return exe.deletingLastPathComponent().appendingPathComponent("keyflash-run").path
        }
        return "/Applications/keyflash.app/Contents/MacOS/keyflash-run"
    }

    // MARK: - Status

    /// Whether the agent will report task completion to keyflash by itself.
    public static func isInstalled(_ agent: Agent) -> Bool {
        switch agent {
        case .claude:
            guard let data = try? Data(contentsOf: claudeSettingsURL),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(marker)
        case .opencode:
            return opencodePluginURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    // MARK: - Install

    /// Installs (or refreshes) the hooks for every agent. Returns one line per
    /// agent describing what happened. Never throws: a failure for one agent
    /// doesn't prevent installing the other.
    @discardableResult
    public static func installAll(runPath: String = defaultRunPath()) -> [String] {
        guard FileManager.default.isExecutableFile(atPath: runPath) else {
            return ["Not installing hooks: keyflash-run not found at \(runPath)"]
        }
        var lines: [String] = []
        do {
            let changed = try installClaude(runPath: runPath)
            lines.append("Claude Code: \(changed ? "hooks installed" : "hooks already up to date") (\(claudeSettingsURL.path))")
        } catch {
            lines.append("Claude Code: FAILED — \(error.localizedDescription)")
        }
        do {
            let changed = try installOpenCode(runPath: runPath)
            lines.append("OpenCode: \(changed ? "plugin installed" : "plugin already up to date") (\(opencodePluginURLs.map(\.path).joined(separator: ", ")))")
        } catch {
            lines.append("OpenCode: FAILED — \(error.localizedDescription)")
        }
        return lines
    }

    /// Removes every hook keyflash installed.
    @discardableResult
    public static func uninstallAll() -> [String] {
        var lines: [String] = []
        do {
            try uninstallClaude()
            lines.append("Claude Code: hooks removed")
        } catch {
            lines.append("Claude Code: FAILED — \(error.localizedDescription)")
        }
        for url in opencodePluginURLs + legacyOpencodePluginURLs {
            try? FileManager.default.removeItem(at: url)
        }
        lines.append("OpenCode: plugin removed")
        return lines
    }

    // MARK: - Claude Code

    /// Claude Code events we hook: matcher (nil = none) and the keyflash alert it maps to.
    static let claudeEvents: [(event: String, matcher: String?, alert: AlertEvent)] = [
        // Main agent finished its turn.
        ("Stop", nil, .done),
        // Claude is blocked waiting on you (tool permission or MCP input).
        ("Notification", "permission_prompt|elicitation_dialog", .attention),
    ]

    /// Returns true if the settings file was changed.
    @discardableResult
    public static func installClaude(runPath: String) throws -> Bool {
        return try updateClaudeSettings { hooks in
            for (event, matcher, alert) in claudeEvents {
                let command = "\(shellQuote(runPath)) --notify claude --event \(alert.rawValue)"
                var groups = try strippedGroups(hooks[event], event: event)
                var group: [String: Any] = [
                    "hooks": [[
                        "type": "command",
                        "command": command,
                        "timeout": 10,
                    ] as [String: Any]],
                ]
                if let matcher { group["matcher"] = matcher }
                groups.append(group)
                hooks[event] = groups
            }
        }
    }

    public static func uninstallClaude() throws {
        try updateClaudeSettings { hooks in
            for (event, _, _) in claudeEvents {
                let groups = try strippedGroups(hooks[event], event: event)
                if groups.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = groups
                }
            }
        }
    }

    /// Loads `~/.claude/settings.json`, lets `mutate` edit its `hooks` object, and
    /// writes it back only if something changed (keeping a backup of the previous
    /// file). Refuses to touch a file it can't parse rather than clobbering it.
    @discardableResult
    static func updateClaudeSettings(_ mutate: (inout [String: Any]) throws -> Void) throws -> Bool {
        // Resolve symlinks so a dotfiles-managed settings.json stays a symlink.
        let url = claudeSettingsURL.resolvingSymlinksInPath()
        let fm = FileManager.default

        var root: [String: Any] = [:]
        var original: Data?
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            original = data
            let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard let obj = try? JSONSerialization.jsonObject(with: data),
                      let dict = obj as? [String: Any] else {
                    throw InstallError(message: "\(url.path) is not valid JSON; fix it or add the hooks manually")
                }
                root = dict
            }
        }

        var hooks: [String: Any] = [:]
        if let raw = root["hooks"] {
            guard let existing = raw as? [String: Any] else {
                throw InstallError(message: "\"hooks\" in \(url.path) is not an object")
            }
            hooks = existing
        }

        let before = root
        try mutate(&hooks)
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        if NSDictionary(dictionary: before).isEqual(to: root as [AnyHashable: Any]) { return false }

        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let original {
            try? writePreservingMode(original, to: url.appendingPathExtension("keyflash-backup"))
            // (the backup takes the original's permissions from the original file itself)
            if let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.appendingPathExtension("keyflash-backup").path)
            }
        }
        try writePreservingMode(out + Data("\n".utf8), to: url)
        return true
    }

    /// Returns the matcher groups for `event` with every keyflash-owned handler
    /// removed (and groups left empty by that removal dropped).
    static func strippedGroups(_ value: Any?, event: String) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let groups = value as? [[String: Any]] else {
            throw InstallError(message: "hooks.\(event) in settings.json has an unexpected format")
        }
        return groups.compactMap { group -> [String: Any]? in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let kept = handlers.filter { handler in
                !((handler["command"] as? String)?.contains(marker) ?? false)
            }
            if kept.count == handlers.count { return group }
            if kept.isEmpty { return nil }
            var copy = group
            copy["hooks"] = kept
            return copy
        }
    }

    // MARK: - OpenCode

    /// Returns true if any plugin file was created or changed.
    @discardableResult
    public static func installOpenCode(runPath: String) throws -> Bool {
        let fm = FileManager.default
        let contents = opencodePluginSource(runPath: runPath)
        var changed = false

        for legacy in legacyOpencodePluginURLs { try? fm.removeItem(at: legacy) }

        for url in opencodePluginURLs {
            if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents { continue }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            changed = true
        }
        return changed
    }

    static func opencodePluginSource(runPath: String) -> String {
        """
        // Installed by keyflash — flashes the keyboard backlight when OpenCode
        // finishes a task or needs your input. Re-created by keyflash on launch
        // (and by `keyflash-run --install-hooks`); remove with `--uninstall-hooks`.
        import { spawn } from "node:child_process"

        const KEYFLASH_RUN = \(jsStringLiteral(runPath))

        function notify(event) {
          try {
            const child = spawn(KEYFLASH_RUN, ["--notify", "opencode", "--event", event], { stdio: "ignore", detached: true })
            child.on("error", () => {})
            child.unref()
          } catch {}
        }

        export const KeyflashPlugin = async ({ client }) => {
          // Sub-agent (task tool) sessions have a parentID; their completion is
          // not the end of your task, so don't flash for them.
          const childSessions = new Set()
          const mainSessions = new Set()

          const isChildSession = async (sessionID) => {
            if (!sessionID) return false
            if (childSessions.has(sessionID)) return true
            if (mainSessions.has(sessionID)) return false
            try {
              const res = await client.session.get({ path: { id: sessionID } })
              const info = res && res.data
              if (info && info.parentID) {
                childSessions.add(sessionID)
                return true
              }
              if (info) mainSessions.add(sessionID)
            } catch {}
            return false
          }

          return {
            event: async ({ event }) => {
              try {
                switch (event && event.type) {
                  case "session.created":
                  case "session.updated": {
                    const info = event.properties && event.properties.info
                    if (info && info.id) (info.parentID ? childSessions : mainSessions).add(info.id)
                    break
                  }
                  case "session.idle":
                    if (!(await isChildSession(event.properties && event.properties.sessionID))) notify("done")
                    break
                  case "session.error": {
                    // Skip sub-agents and runs you aborted yourself (Esc).
                    const props = event.properties || {}
                    const name = props.error && props.error.name
                    if (name !== "MessageAbortedError" && !(await isChildSession(props.sessionID))) notify("error")
                    break
                  }
                  case "permission.asked":
                  case "permission.updated":
                  case "question.asked":
                    notify("attention")
                    break
                }
              } catch {}
            },
          }
        }

        """
    }

    // MARK: - Quoting helpers

    /// Single-quotes a string for POSIX shells.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Encodes a string as a JavaScript (JSON) string literal.
    static func jsStringLiteral(_ s: String) -> String {
        if let data = try? JSONEncoder().encode(s), let lit = String(data: data, encoding: .utf8) {
            return lit
        }
        return "\"\(s)\""
    }
}
