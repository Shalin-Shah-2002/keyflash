import Foundation
import XCTest
@testable import KeyflashCore

final class PTYSpawnTests: XCTestCase {
    private var helper: String { productsDirectory.appendingPathComponent("keyflash-run").path }
    private var savedStdin: Int32 = -1

    // Give every test a stdin that is at EOF (like CI), so results never depend
    // on the developer's terminal: an interactive stdin would make `cat` wait forever.
    override func setUp() {
        savedStdin = dup(STDIN_FILENO)
        let devNull = open("/dev/null", O_RDONLY)
        dup2(devNull, STDIN_FILENO)
        close(devNull)
    }

    override func tearDown() {
        dup2(savedStdin, STDIN_FILENO)
        close(savedStdin)
    }

    private func run(_ script: String, helper: String? = nil) -> Int32 {
        PTYSpawn().run(command: ["/bin/sh", "-c", script], execHelper: helper).exitCode
    }

    func testExitCodeIsPreserved() {
        XCTAssertEqual(run("exit 0"), 0)
        XCTAssertEqual(run("exit 3"), 3)
        XCTAssertEqual(run("exit 3", helper: helper), 3)
    }

    func testKilledChildReports128PlusSignal() {
        XCTAssertEqual(run("kill -9 $$"), 137)
    }

    func testEnvironmentIsPassedThrough() {
        setenv("KEYFLASH_TEST_VAR", "hello world", 1)
        defer { unsetenv("KEYFLASH_TEST_VAR") }
        XCTAssertEqual(run("[ \"$KEYFLASH_TEST_VAR\" = 'hello world' ] && [ -n \"$PATH\" ] && [ -n \"$HOME\" ]"), 0)
        XCTAssertEqual(run("[ -n \"$TERM\" ]"), 0)
    }

    func testCommandsAreFoundViaPath() {
        XCTAssertEqual(PTYSpawn().run(command: ["sh", "-c", "exit 5"]).exitCode, 5)
        XCTAssertEqual(PTYSpawn().run(command: ["sh", "-c", "exit 5"], execHelper: helper).exitCode, 5)
    }

    func testMissingCommandIs127() {
        XCTAssertEqual(PTYSpawn().run(command: ["definitely-not-a-command-kf"]).exitCode, 127)
        XCTAssertEqual(PTYSpawn().run(command: ["definitely-not-a-command-kf"], execHelper: helper).exitCode, 127)
    }

    func testChildRunsOnATerminal() {
        XCTAssertEqual(run("[ -t 0 ] && [ -t 1 ]"), 0)
    }

    func testHelperGivesChildAControllingTerminal() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper), "build keyflash-run first: \(helper)")
        // /dev/tty only opens if the PTY is the child's controlling terminal
        // (needed for Ctrl-C, git/ssh/sudo prompts).
        XCTAssertEqual(run("exec 3</dev/tty && exit 0", helper: helper), 0)
    }

    func testStdinEOFDoesNotHang() {
        // Test stdin is not interactive; cat must see EOF and exit instead of hanging.
        let start = Date()
        XCTAssertEqual(run("cat >/dev/null; exit 0", helper: helper), 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    /// Runs `body` with stdin redirected from a file with the given contents.
    private func withStdin(_ contents: String, _ body: () -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kf-stdin-\(UUID().uuidString.prefix(8))")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY)
        defer { close(fd) }
        dup2(fd, STDIN_FILENO)   // tearDown restores the original stdin
        body()
    }

    func testRedirectedFileInputReachesTheChild() throws {
        try withStdin("hello\n") {
            XCTAssertEqual(run("read x; [ \"$x\" = hello ]", helper: helper), 0)
        }
    }

    func testLargeInputIsDeliveredCompletelyWithoutDeadlock() throws {
        let line = "0123456789abcdef\n"   // short lines: a terminal drops lines over 4095 bytes
        try withStdin(String(repeating: line, count: 20_000)) {
            // 340,000 bytes: far more than the PTY buffers, so this needs backpressure.
            XCTAssertEqual(run("stty -echo; n=$(cat | wc -c); [ \"$n\" -eq 340000 ]", helper: helper), 0)
        }
    }

    func testTerminationSignalIsForwardedToChild() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { kill(getpid(), SIGTERM) }
        let code = run("sleep 20", helper: helper)
        XCTAssertEqual(code, 128 + SIGTERM)
    }

    func testExitCodeDecoding() {
        XCTAssertEqual(PTYSpawn.exitCode(fromWaitStatus: 3 << 8), 3)
        XCTAssertEqual(PTYSpawn.exitCode(fromWaitStatus: 9), 137)
    }
}
