import Foundation
import XCTest
@testable import KeyflashCore

final class ShellHookInstallerTests: SandboxedTestCase {
    func testStripNeverJoinsSurroundingLines() {
        let block = "# >>> keyflash >>>\nalias claude='x -- claude'\n# <<< keyflash <<<\n"
        XCTAssertEqual(ShellHookInstaller.stripHook("export A=1\n\n" + block + "export B=2\n"), "export A=1\nexport B=2\n")
        XCTAssertEqual(ShellHookInstaller.stripHook("export A=1\n" + block + "export B=2\n"), "export A=1\nexport B=2\n")
        XCTAssertEqual(ShellHookInstaller.stripHook(block), "")
        XCTAssertEqual(ShellHookInstaller.stripHook("a\n"), "a\n")
    }

    func testInstallRemovesOldAliasesAndIsIdempotent() throws {
        try write("""
        export PATH=/x:$PATH

        # >>> keyflash >>>
        alias claude='/Applications/keyflash.app/Contents/MacOS/keyflash-run -- claude'
        alias opencode='/Applications/keyflash.app/Contents/MacOS/keyflash-run -- opencode'
        # <<< keyflash <<<
        export AFTER=1

        """, to: ".zshrc")

        let status = ShellHookInstaller.installIfNeeded(shell: "/bin/zsh")
        XCTAssertTrue(status.contains("installed"), status)
        let rc = try XCTUnwrap(read(".zshrc"))
        XCTAssertFalse(rc.contains("alias claude"))
        XCTAssertFalse(rc.contains("alias opencode"))
        XCTAssertTrue(rc.contains("export PATH=/x:$PATH\nexport AFTER=1\n"))
        XCTAssertTrue(rc.contains("function aider {"))
        XCTAssertEqual(rc.components(separatedBy: "# >>> keyflash >>>").count, 2)

        XCTAssertTrue(ShellHookInstaller.installIfNeeded(shell: "/bin/zsh").contains("up to date"))
        XCTAssertEqual(read(".zshrc"), rc)
    }

    func testBashUsesBashProfileAndCleansOtherFiles() throws {
        try write("# >>> keyflash >>>\nalias claude=x\n# <<< keyflash <<<\n", to: ".zshrc")
        _ = ShellHookInstaller.installIfNeeded(shell: "/bin/bash")
        XCTAssertEqual(read(".zshrc"), "")
        XCTAssertTrue(read(".bash_profile")?.contains("function aider {") ?? false)
    }

    func testNonUTF8RcFileIsNeverOverwritten() throws {
        let url = home.appendingPathComponent(".zshrc")
        let bytes = Data([0x65, 0x78, 0x70, 0x6F, 0x72, 0x74, 0x20, 0x58, 0x3D, 0xE9, 0x0A])  // Latin-1 "é"
        try bytes.write(to: url)
        let status = ShellHookInstaller.installIfNeeded(shell: "/bin/zsh")
        XCTAssertTrue(status.contains("FAILED"), status)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testRcFilePermissionsArePreserved() throws {
        try write("export A=1\n", to: ".zshrc")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent(".zshrc").path)
        _ = ShellHookInstaller.installIfNeeded(shell: "/bin/zsh")
        let mode = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".zshrc").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    /// Runs the installed function under bash with a fake `aider` and returns the
    /// arguments the real `aider` would receive (one per line).
    private func runAider(rc: String, args: [String]) throws -> [String] {
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("aider")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "source \"$1\"; shift; aider \"$@\"", "bash", rc] + args
        task.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path]
        let out = Pipe()
        task.standardOutput = out
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func testAiderFunctionAddsTheNotificationFlagsAndKeepsYourArguments() throws {
        // A run path with a space and a quote checks the quoting all the way through.
        let run = home.appendingPathComponent("it's here/keyflash-run")
        try FileManager.default.createDirectory(at: run.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: run, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)

        _ = ShellHookInstaller.installIfNeeded(shell: "/bin/bash", runPath: run.path)
        let received = try runAider(rc: home.appendingPathComponent(".bash_profile").path, args: ["--model", "sonnet", "fix it"])

        XCTAssertEqual(received.count, 6, "\(received)")
        XCTAssertEqual(received[0], "--notifications")
        XCTAssertEqual(received[1], "--notifications-command")
        // aider runs this through a shell, so it must parse back to the exact binary.
        XCTAssertEqual(received[2], "'\(run.path.replacingOccurrences(of: "'", with: "'\\''"))' --notify aider --event done")
        XCTAssertEqual(Array(received[3...]), ["--model", "sonnet", "fix it"])
    }

    func testAiderNotifyCommandRunsTheRealBinaryWithTheRightArguments() throws {
        let run = home.appendingPathComponent("it's here/keyflash-run")
        try FileManager.default.createDirectory(at: run.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"$@\" > \"$(dirname \"$0\")/args.txt\"\n".write(to: run, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")   // what aider does with the command
        task.arguments = ["-c", ShellHookInstaller.aiderNotifyCommand(runPath: run.path)]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: run.deletingLastPathComponent().appendingPathComponent("args.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "--notify aider --event done")
    }

    func testAiderFunctionIsNotDefinedWhenTheAppIsGone() throws {
        _ = ShellHookInstaller.installIfNeeded(shell: "/bin/bash", runPath: "/nonexistent/keyflash-run")
        // The guard leaves plain `aider` untouched instead of breaking it.
        let received = try runAider(rc: home.appendingPathComponent(".bash_profile").path, args: ["hello"])
        XCTAssertEqual(received, ["hello"])
    }

    func testRefreshRepointsAnInstalledHookInPlace() throws {
        let old = home.appendingPathComponent("old/keyflash-run")
        let new = home.appendingPathComponent("new/keyflash-run")
        for url in [old, new] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try write("export TOP=1\n", to: ".zshrc")
        _ = ShellHookInstaller.installIfNeeded(shell: "/bin/zsh", runPath: old.path)
        try write((read(".zshrc") ?? "") + "export BOTTOM=2\n", to: ".zshrc")
        XCTAssertTrue(ShellHookInstaller.isInstalled)

        XCTAssertEqual(ShellHookInstaller.refreshInstalled(runPath: new.path).count, 1)
        let rc = try XCTUnwrap(read(".zshrc"))
        XCTAssertTrue(rc.contains(new.path))
        XCTAssertFalse(rc.contains(old.path))
        XCTAssertTrue(rc.hasPrefix("export TOP=1\n"), "your lines stay where they were")
        XCTAssertTrue(rc.hasSuffix("export BOTTOM=2\n"))
        XCTAssertEqual(rc.components(separatedBy: "# >>> keyflash >>>").count, 2)
        XCTAssertTrue(ShellHookInstaller.refreshInstalled(runPath: new.path).isEmpty, "nothing left to change")
    }

    func testRefreshNeverInstallsWhereThereIsNoHook() throws {
        let run = home.appendingPathComponent("keyflash-run")
        try "#!/bin/sh\n".write(to: run, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)
        try write("export A=1\n", to: ".zshrc")
        XCTAssertFalse(ShellHookInstaller.isInstalled)
        XCTAssertTrue(ShellHookInstaller.refreshInstalled(runPath: run.path).isEmpty)
        XCTAssertEqual(read(".zshrc"), "export A=1\n")
    }

    /// rc files are sourced by bash/zsh (`function name {}` is valid in both).
    func testGeneratedHookIsValidBash() throws {
        _ = ShellHookInstaller.installIfNeeded(shell: "/bin/bash")
        let rc = home.appendingPathComponent(".bash_profile").path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-n", rc]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
    }
}
