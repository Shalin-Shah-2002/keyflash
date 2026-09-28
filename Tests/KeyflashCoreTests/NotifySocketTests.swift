import Foundation
import XCTest
@testable import KeyflashCore

final class NotifySocketTests: SandboxedTestCase {
    func testRoundTrip() throws {
        let received = expectation(description: "received")
        var got: (String, Int)?
        let server = NotifyServer(handlerQueue: DispatchQueue(label: "test")) { agent, pid in
            got = (agent, pid)
            received.fulfill()
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        XCTAssertTrue(KeyflashPaths.socketPath.hasPrefix(home.path) || KeyflashPaths.socketPath.hasPrefix("/tmp/keyflash-"))
        XCTAssertTrue(NotifyClient.sendDone(agent: "claude", pid: 42))
        wait(for: [received], timeout: 5)
        XCTAssertEqual(got?.0, "claude")
        XCTAssertEqual(got?.1, 42)

        // Socket is private to the user.
        var st = stat()
        XCTAssertEqual(lstat(KeyflashPaths.socketPath, &st), 0)
        XCTAssertEqual(Int(st.st_mode) & 0o077, 0)
    }

    func testClientFailsFastWhenAppNotRunning() {
        let start = Date()
        XCTAssertFalse(NotifyClient.sendDone(agent: "claude", pid: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testStuckClientDoesNotBlockOthers() throws {
        let received = expectation(description: "received")
        let server = NotifyServer(handlerQueue: DispatchQueue(label: "test")) { _, _ in received.fulfill() }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        // Connect and send nothing.
        let path = KeyflashPaths.socketPath
        let fd = socket(AF_UNIX, testStreamType, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, b) in path.utf8.enumerated() { ptr[i] = b }
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        defer { close(fd) }

        XCTAssertTrue(NotifyClient.sendDone(agent: "opencode", pid: 7))
        wait(for: [received], timeout: 5)
    }

    func testRestartReplacesStaleSocket() {
        let first = NotifyServer(handlerQueue: DispatchQueue(label: "t1")) { _, _ in }
        XCTAssertTrue(first.start())
        // Simulate a crash: the socket file is left behind.
        let second = NotifyServer(handlerQueue: DispatchQueue(label: "t2")) { _, _ in }
        XCTAssertTrue(second.start())
        second.stop()
        first.stop()
    }

    func testParse() {
        XCTAssertEqual(NotifyServer.parse(Array("agent=claude pid=12\n".utf8))?.0, "claude")
        XCTAssertEqual(NotifyServer.parse(Array("agent=claude pid=12\n".utf8))?.1, 12)
        XCTAssertNil(NotifyServer.parse(Array("garbage".utf8)))
        XCTAssertNil(NotifyServer.parse([0xff, 0xfe]))
    }
}

#if canImport(Darwin)
private let testStreamType = SOCK_STREAM
#else
private let testStreamType = Int32(SOCK_STREAM.rawValue)
#endif
