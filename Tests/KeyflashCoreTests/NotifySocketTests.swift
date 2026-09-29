import Foundation
import XCTest
@testable import KeyflashCore

final class NotifySocketTests: SandboxedTestCase {
    /// Every test gets its own short socket path. Never use the default path
    /// here: on a machine running keyflash it would replace the real app's socket.
    private var socketPath = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        socketPath = "/tmp/kft-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDownWithError() throws {
        unlink(socketPath)
        try super.tearDownWithError()
    }

    private func makeServer(_ handler: @escaping (NotifyMessage) -> Void = { _ in }) -> NotifyServer {
        NotifyServer(socketPath: socketPath, handlerQueue: DispatchQueue(label: "test"), handler: handler)
    }

    func testRoundTripCarriesEvent() throws {
        for event in AlertEvent.allCases {
            let received = expectation(description: "received \(event)")
            var got: NotifyMessage?
            let server = makeServer { got = $0; received.fulfill() }
            XCTAssertTrue(server.start())

            XCTAssertTrue(NotifyClient.send(agent: "claude", pid: 42, event: event, ancestors: [900, 800, 700], socketPath: socketPath))
            wait(for: [received], timeout: 5)
            server.stop()
            XCTAssertEqual(got, NotifyMessage(agent: "claude", pid: 42, event: event, ancestors: [900, 800, 700]))
        }
    }

    func testClientSendsItsAncestorsByDefault() throws {
        let received = expectation(description: "received")
        var got: NotifyMessage?
        let server = makeServer { got = $0; received.fulfill() }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        XCTAssertTrue(NotifyClient.send(agent: "claude", pid: 1, socketPath: socketPath))
        wait(for: [received], timeout: 5)
        XCTAssertEqual(got?.ancestors.first, Int(getppid()), "starts at the sender's parent")
    }

    func testSocketIsPrivateToTheUser() {
        let server = makeServer()
        XCTAssertTrue(server.start())
        defer { server.stop() }
        var st = stat()
        XCTAssertEqual(lstat(socketPath, &st), 0)
        XCTAssertEqual(Int(st.st_mode) & 0o077, 0)
    }

    func testDefaultPathIsPerUser() {
        XCTAssertTrue(KeyflashPaths.socketPath.hasPrefix(home.path) || KeyflashPaths.socketPath.hasPrefix("/tmp/keyflash-"))
    }

    func testClientFailsFastWhenAppNotRunning() {
        let start = Date()
        XCTAssertFalse(NotifyClient.send(agent: "claude", pid: 1, socketPath: socketPath))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testStuckClientDoesNotBlockOthers() throws {
        let received = expectation(description: "received")
        let server = makeServer { _ in received.fulfill() }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        // Connect and send nothing.
        let fd = socket(AF_UNIX, testStreamType, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, b) in socketPath.utf8.enumerated() { ptr[i] = b }
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        defer { close(fd) }

        XCTAssertTrue(NotifyClient.send(agent: "opencode", pid: 7, socketPath: socketPath))
        wait(for: [received], timeout: 5)
    }

    func testSecondServerCannotStealALiveSocket() {
        let first = makeServer()
        XCTAssertTrue(first.start())
        let second = makeServer()
        XCTAssertFalse(second.start(), "must not replace a socket another keyflash is listening on")

        // The first server still receives messages.
        first.stop()
        XCTAssertTrue(second.start(), "free again once the first stops")
        second.stop()
    }

    func testStaleSocketFileFromACrashIsReplaced() {
        // Bind a socket and abandon it without unlinking: what a crash leaves behind.
        let fd = socket(AF_UNIX, testStreamType, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, b) in socketPath.utf8.enumerated() { ptr[i] = b }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawBind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let server = makeServer()
        XCTAssertTrue(server.start())
        server.stop()
    }

    func testRegularFileAtSocketPathIsNotDeleted() throws {
        try "precious".write(toFile: socketPath, atomically: true, encoding: .utf8)
        let server = makeServer()
        XCTAssertFalse(server.start())
        XCTAssertEqual(try String(contentsOfFile: socketPath, encoding: .utf8), "precious")
    }

    func testMessageArrivingInPiecesIsReassembled() throws {
        let received = expectation(description: "received")
        var got: NotifyMessage?
        let server = makeServer { got = $0; received.fulfill() }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        let fd = socket(AF_UNIX, testStreamType, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, b) in socketPath.utf8.enumerated() { ptr[i] = b }
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        defer { close(fd) }
        for piece in ["agent=clau", "de pid=9 eve", "nt=attention\n"] {
            _ = piece.withCString { rawWrite(fd, $0, strlen($0)) }
            usleep(50_000)
        }
        wait(for: [received], timeout: 5)
        XCTAssertEqual(got, NotifyMessage(agent: "claude", pid: 9, event: .attention))
    }

    func testParse() {
        XCTAssertEqual(NotifyServer.parse(Array("agent=claude pid=12\n".utf8)),
                       NotifyMessage(agent: "claude", pid: 12, event: .done))
        XCTAssertEqual(NotifyServer.parse(Array("agent=claude pid=12 event=attention\n".utf8))?.event, .attention)
        XCTAssertEqual(NotifyServer.parse(Array("agent=x pid=1 event=error\n".utf8))?.event, .error)
        XCTAssertEqual(NotifyServer.parse(Array("agent=x pid=1 event=bogus\n".utf8))?.event, .done, "unknown falls back to done")
        XCTAssertEqual(NotifyServer.parse(Array("agent=x pid=1 ancestors=30,20,10\n".utf8))?.ancestors, [30, 20, 10])
        XCTAssertEqual(NotifyServer.parse(Array("agent=x pid=1 ancestors=30,zz,10\n".utf8))?.ancestors, [30, 10], "bad entries are skipped")
        let many = (1...500).map(String.init).joined(separator: ",")
        XCTAssertEqual(NotifyServer.parse(Array("agent=x pid=1 ancestors=\(many)\n".utf8))?.ancestors.count, 64, "capped")
        XCTAssertNil(NotifyServer.parse(Array("garbage".utf8)))
        XCTAssertNil(NotifyServer.parse([0xff, 0xfe]))
    }
}

/// bind(2) (inside a test case on macOS, a plain `bind` resolves to NSObject's KVO `bind`).
private func rawBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { bind(fd, addr, len) }

/// write(2) (a plain `write` inside the test case resolves to the helper method).
private func rawWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ len: Int) -> Int { write(fd, buf, len) }

#if canImport(Darwin)
private let testStreamType = SOCK_STREAM
#else
private let testStreamType = Int32(SOCK_STREAM.rawValue)
#endif
