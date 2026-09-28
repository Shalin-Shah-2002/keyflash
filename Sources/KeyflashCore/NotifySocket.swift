import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Task-completion messages travel from `keyflash-run --notify` (client) to the
// menu bar app (server) over a per-user Unix domain socket, because
// `DistributedNotificationCenter` is unreliable for unsigned apps on macOS 26.
//
// Wire format: one line, "agent=<name> pid=<pid>\n".

private func makeUnixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
        for (i, byte) in bytes.enumerated() { ptr[i] = byte }
        ptr[bytes.count] = 0
    }
    return addr
}

private func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

#if canImport(Darwin)
private let streamSocketType = SOCK_STREAM
#else
private let streamSocketType = Int32(SOCK_STREAM.rawValue)
#endif

/// Client side, used by `keyflash-run --notify` (called from agent hooks).
public enum NotifyClient {
    /// Sends one task-done message. Returns false if the app isn't reachable.
    /// Never blocks for long and never raises SIGPIPE.
    @discardableResult
    public static func sendDone(agent: String, pid: Int, socketPath: String = KeyflashPaths.socketPath) -> Bool {
        let fd = socket(AF_UNIX, streamSocketType, 0)
        guard fd >= 0 else {
            keyflashLog("NotifyClient: failed to create socket: \(String(cString: strerror(errno)))")
            return false
        }
        defer { close(fd) }

        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard var addr = makeUnixAddress(socketPath) else { return false }
        let connected = withSockaddr(&addr) { connect(fd, $0, $1) }
        guard connected == 0 else {
            keyflashLog("NotifyClient: menu bar app not reachable at \(socketPath): \(String(cString: strerror(errno)))")
            return false
        }

        let safeAgent = agent.filter { !$0.isWhitespace && $0 != "=" }
        let bytes = Array("agent=\(safeAgent.isEmpty ? "agent" : safeAgent) pid=\(pid)\n".utf8)
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, flags) }
        keyflashLog("NotifyClient: sent taskDone agent=\(safeAgent) (\(sent) bytes)")
        return sent == bytes.count
    }
}

/// Server side, used by the menu bar app. Accepts and reads on a background
/// queue so a slow or stuck client can never freeze the UI; `handler` is
/// called on `handlerQueue` (main by default).
public final class NotifyServer {
    private let handler: (String, Int) -> Void
    private let handlerQueue: DispatchQueue
    private let socketPath: String
    private let queue = DispatchQueue(label: "keyflash.notify-socket")
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(socketPath: String = KeyflashPaths.socketPath,
                handlerQueue: DispatchQueue = .main,
                handler: @escaping (_ agent: String, _ pid: Int) -> Void) {
        self.socketPath = socketPath
        self.handlerQueue = handlerQueue
        self.handler = handler
    }

    public var isListening: Bool { source != nil }

    /// Starts listening. Returns false (and logs why) if the socket can't be set up.
    @discardableResult
    public func start() -> Bool {
        guard source == nil else { return true }
        if socketPath == KeyflashPaths.socketPath { KeyflashPaths.ensureSocketDirectory() }

        // Remove a stale socket left by a previous run (only if it is a socket).
        var st = stat()
        if lstat(socketPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK {
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, streamSocketType, 0)
        guard fd >= 0 else {
            keyflashLog("NotifyServer: failed to create socket: \(String(cString: strerror(errno)))")
            return false
        }
        guard var addr = makeUnixAddress(socketPath) else {
            keyflashLog("NotifyServer: socket path too long: \(socketPath)")
            close(fd)
            return false
        }
        let bound = withSockaddr(&addr) { bind(fd, $0, $1) }
        guard bound == 0 else {
            keyflashLog("NotifyServer: failed to bind \(socketPath): \(String(cString: strerror(errno)))")
            close(fd)
            return false
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else {
            keyflashLog("NotifyServer: failed to listen: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(socketPath)
            return false
        }

        socketFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptConnection(listenFD: fd) }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        keyflashLog("NotifyServer: listening on \(socketPath)")
        return true
    }

    public func stop() {
        guard let src = source else { return }
        source = nil
        socketFD = -1
        src.cancel()
        unlink(socketPath)
    }

    deinit { stop() }

    private func acceptConnection(listenFD: Int32) {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 1024)
        let n = read(clientFD, &buf, buf.count)
        guard n > 0, let (agent, pid) = NotifyServer.parse(Array(buf.prefix(n))) else { return }
        keyflashLog("NotifyServer: received taskDone agent=\(agent) pid=\(pid)")
        let handler = self.handler
        handlerQueue.async { handler(agent, pid) }
    }

    /// Parses "agent=<name> pid=<pid>". Returns nil for anything else.
    static func parse(_ bytes: [UInt8]) -> (String, Int)? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var agent: String?
        var pid = 0
        for part in line.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0] == "agent" { agent = String(kv[1]) }
            if kv[0] == "pid" { pid = Int(kv[1]) ?? 0 }
        }
        guard let agent, !agent.isEmpty else { return nil }
        return (agent, pid)
    }
}
