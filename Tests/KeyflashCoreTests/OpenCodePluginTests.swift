import Foundation
import XCTest
@testable import KeyflashCore

/// Runs the generated OpenCode plugin under Node with simulated OpenCode
/// events and checks which `keyflash-run --notify` calls it makes.
final class OpenCodePluginTests: SandboxedTestCase {
    private func nodeIsAvailable() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["node", "--version"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    func testPluginSendsTheRightEvents() throws {
        try XCTSkipUnless(nodeIsAvailable(), "node is not installed")

        // The runner path contains a space to exercise quoting.
        let dir = home.appendingPathComponent("plugin test", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = dir.appendingPathComponent("keyflash-run")
        try "#!/bin/sh\necho \"$@\" >> \"$(dirname \"$0\")/calls.log\"\n".write(to: runner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)

        // `.mjs`: the plugin uses ES module syntax.
        try AgentHooks.opencodePluginSource(runPath: runner.path)
            .write(to: dir.appendingPathComponent("keyflash.mjs"), atomically: true, encoding: .utf8)

        try """
        import * as mod from "./keyflash.mjs"
        const exported = Object.values(mod)
        if (exported.length !== 1 || typeof exported[0] !== "function") throw new Error("plugin must export exactly one function")

        const client = { session: { get: async ({ path }) => {
          if (path.id === "boom") throw new Error("network")
          return { data: path.id === "child2" ? { id: "child2", parentID: "main" } : { id: path.id } }
        } } }
        const hooks = await exported[0]({ client })
        const send = (type, properties) => hooks.event({ event: { type, properties } })

        await send("session.created", { info: { id: "child1", parentID: "main" } })
        await send("session.idle", { sessionID: "child1" })                                  // sub-agent: nothing
        await send("session.idle", { sessionID: "child2" })                                  // sub-agent (looked up): nothing
        await send("session.idle", { sessionID: "main" })                                    // done
        await send("session.idle", { sessionID: "boom" })                                    // lookup fails: done
        await send("permission.asked", { sessionID: "child1" })                              // attention
        await send("question.asked", {})                                                     // attention
        await send("session.error", { sessionID: "main", error: { name: "MessageAbortedError" } }) // you pressed Esc: nothing
        await send("session.error", { sessionID: "main", error: { name: "UnknownError" } })  // error
        await send("session.error", { sessionID: "child1", error: { name: "UnknownError" } }) // sub-agent: nothing
        await send("message.updated", {})                                                    // nothing
        await hooks.event({ event: null })                                                   // must not throw
        await new Promise(r => setTimeout(r, 800))
        """.write(to: dir.appendingPathComponent("driver.mjs"), atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["node", "driver.mjs"]
        task.currentDirectoryURL = dir
        let err = Pipe()
        task.standardError = err
        try task.run()
        task.waitUntilExit()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(task.terminationStatus, 0, stderr)

        let calls = (try String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8))
            .split(separator: "\n").map(String.init).sorted()
        XCTAssertEqual(calls, [
            "--notify opencode --event attention",
            "--notify opencode --event attention",
            "--notify opencode --event done",
            "--notify opencode --event done",
            "--notify opencode --event error",
        ])
    }
}
