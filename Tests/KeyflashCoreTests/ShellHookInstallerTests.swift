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
