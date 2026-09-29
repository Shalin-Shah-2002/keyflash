import Foundation
import XCTest
@testable import KeyflashCore

final class AgentHooksTests: SandboxedTestCase {
    let runPath = "/Applications/key flash.app/Contents/MacOS/keyflash-run"

    private func claudeCommands(_ root: [String: Any], _ event: String) -> [String] {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testFreshInstallCreatesStopAndNotificationHooks() throws {
        XCTAssertFalse(AgentHooks.isInstalled(.claude))
        XCTAssertTrue(try AgentHooks.installClaude(runPath: runPath))

        let root = try json(".claude/settings.json")
        XCTAssertEqual(claudeCommands(root, "Stop"), ["'\(runPath)' --notify claude --event done"])
        XCTAssertEqual(claudeCommands(root, "Notification"), ["'\(runPath)' --notify claude --event attention"])
        let notif = ((root["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]])?.first
        XCTAssertEqual(notif?["matcher"] as? String, "permission_prompt|elicitation_dialog")
        let stop = ((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first
        XCTAssertNil(stop?["matcher"], "Stop hooks don't take a matcher")
        XCTAssertTrue(AgentHooks.isInstalled(.claude))
    }

    func testInstallPreservesExistingSettingsAndUserHooks() throws {
        try write("""
        {
          "model": "opus",
          "permissions": { "allow": ["Bash(ls:*)"] },
          "hooks": {
            "Stop": [ { "hooks": [ { "type": "command", "command": "say done" } ] } ],
            "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "audit.sh" } ] } ]
          }
        }
        """, to: ".claude/settings.json")

        XCTAssertTrue(try AgentHooks.installClaude(runPath: runPath))
        let root = try json(".claude/settings.json")
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual((root["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
        XCTAssertEqual(claudeCommands(root, "Stop"), ["say done", "'\(runPath)' --notify claude --event done"])
        XCTAssertEqual(claudeCommands(root, "PreToolUse"), ["audit.sh"])

        // A backup of the original file is kept.
        XCTAssertTrue(read(".claude/settings.json.keyflash-backup")?.contains("say done") ?? false)
    }

    func testInstallIsIdempotent() throws {
        XCTAssertTrue(try AgentHooks.installClaude(runPath: runPath))
        let first = read(".claude/settings.json")
        XCTAssertFalse(try AgentHooks.installClaude(runPath: runPath))
        XCTAssertEqual(read(".claude/settings.json"), first)
    }

    func testReinstallWithNewPathReplacesOldEntry() throws {
        try AgentHooks.installClaude(runPath: "/old/keyflash-run")
        XCTAssertTrue(try AgentHooks.installClaude(runPath: runPath))
        let root = try json(".claude/settings.json")
        XCTAssertEqual(claudeCommands(root, "Stop"), ["'\(runPath)' --notify claude --event done"])
        XCTAssertEqual(claudeCommands(root, "Notification"), ["'\(runPath)' --notify claude --event attention"])
    }

    func testOldHooksWithoutEventAreUpgraded() throws {
        try write("""
        { "hooks": { "Notification": [ { "matcher": "permission_prompt", "hooks": [ { "type": "command", "command": "'/old/keyflash-run' --notify claude" } ] } ] } }
        """, to: ".claude/settings.json")
        XCTAssertTrue(try AgentHooks.installClaude(runPath: runPath))
        let root = try json(".claude/settings.json")
        XCTAssertEqual(claudeCommands(root, "Notification"), ["'\(runPath)' --notify claude --event attention"])
    }

    func testInvalidJSONIsLeftUntouched() throws {
        let broken = "{ \"model\": \"opus\", // comment\n }"
        try write(broken, to: ".claude/settings.json")
        XCTAssertThrowsError(try AgentHooks.installClaude(runPath: runPath))
        XCTAssertEqual(read(".claude/settings.json"), broken)
    }

    func testUnexpectedHooksShapeIsLeftUntouched() throws {
        let odd = "{ \"hooks\": { \"Stop\": \"not-an-array\" } }"
        try write(odd, to: ".claude/settings.json")
        XCTAssertThrowsError(try AgentHooks.installClaude(runPath: runPath))
        XCTAssertEqual(read(".claude/settings.json"), odd)
    }

    func testSymlinkedSettingsStaysASymlink() throws {
        try write("{}", to: "dotfiles/claude-settings.json")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".claude/settings.json"),
            withDestinationURL: home.appendingPathComponent("dotfiles/claude-settings.json"))

        try AgentHooks.installClaude(runPath: runPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".claude/settings.json").path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertTrue(read("dotfiles/claude-settings.json")?.contains("--notify claude") ?? false)
    }

    func testSettingsPermissionsSurviveAndBackupIsNotWorldReadable() throws {
        try write("{ \"env\": { \"ANTHROPIC_API_KEY\": \"secret\" } }", to: ".claude/settings.json")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)

        try AgentHooks.installClaude(runPath: runPath)

        func mode(_ url: URL) throws -> Int? {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        XCTAssertEqual(try mode(settings), 0o600)
        XCTAssertEqual(try mode(home.appendingPathComponent(".claude/settings.json.keyflash-backup")), 0o600)
    }

    func testNewSettingsFileIsPrivate() throws {
        try AgentHooks.installClaude(runPath: runPath)
        let mode = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".claude/settings.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testUninstallRemovesOnlyKeyflashHooks() throws {
        try write("""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "say done" } ] } ] } }
        """, to: ".claude/settings.json")
        try AgentHooks.installClaude(runPath: runPath)
        try AgentHooks.uninstallClaude()

        let root = try json(".claude/settings.json")
        XCTAssertEqual(claudeCommands(root, "Stop"), ["say done"])
        XCTAssertNil((root["hooks"] as? [String: Any])?["Notification"])
        XCTAssertFalse(AgentHooks.isInstalled(.claude))
    }

    func testUninstallDropsEmptyHooksObject() throws {
        try write("{ \"model\": \"opus\" }", to: ".claude/settings.json")
        try AgentHooks.installClaude(runPath: runPath)
        try AgentHooks.uninstallClaude()
        let root = try json(".claude/settings.json")
        XCTAssertNil(root["hooks"])
        XCTAssertEqual(root["model"] as? String, "opus")
    }

    func testOpenCodePluginInstallAndLegacyCleanup() throws {
        try write("old", to: ".config/opencode/plugin/keyflash.js")
        XCTAssertTrue(try AgentHooks.installOpenCode(runPath: runPath))
        XCTAssertFalse(try AgentHooks.installOpenCode(runPath: runPath))
        XCTAssertNil(read(".config/opencode/plugin/keyflash.js"), "legacy copy would fire twice")

        let plugin = try XCTUnwrap(read(".config/opencode/plugins/keyflash.js"))
        XCTAssertTrue(plugin.contains("const KEYFLASH_RUN = \"\\/Applications\\/key flash.app\\/Contents\\/MacOS\\/keyflash-run\""))
        XCTAssertTrue(plugin.contains("session.idle"))
        XCTAssertTrue(plugin.contains("notify(\"attention\")"))
        XCTAssertTrue(plugin.contains("notify(\"error\")"))
        XCTAssertEqual(plugin.components(separatedBy: "export ").count - 1, 1, "OpenCode calls every export")
        XCTAssertTrue(AgentHooks.isInstalled(.opencode))
    }

    func testInstallAllRequiresExecutable() {
        let lines = AgentHooks.installAll(runPath: home.appendingPathComponent("missing").path)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("not found"))
        XCTAssertFalse(AgentHooks.isInstalled(.claude))
    }

    func testInstallAllAndUninstallAll() throws {
        let fake = home.appendingPathComponent("keyflash-run")
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let lines = AgentHooks.installAll(runPath: fake.path)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.contains { $0.contains("FAILED") }, lines.joined(separator: "\n"))
        XCTAssertTrue(AgentHooks.isInstalled(.claude))
        XCTAssertTrue(AgentHooks.isInstalled(.opencode))

        AgentHooks.uninstallAll()
        XCTAssertFalse(AgentHooks.isInstalled(.claude))
        XCTAssertFalse(AgentHooks.isInstalled(.opencode))
    }

    func testShellQuote() {
        XCTAssertEqual(AgentHooks.shellQuote("/a b/c"), "'/a b/c'")
        XCTAssertEqual(AgentHooks.shellQuote("it's"), "'it'\\''s'")
    }
}
