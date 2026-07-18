import Foundation

/// Listens for task-completion notifications from `keyflash-run` CLI instances.
///
/// Uses a Unix domain socket at `/tmp/keyflash.sock` because
/// `DistributedNotificationCenter` is unreliable for unsigned apps on macOS 26.
public class NotificationService: NSObject {
    private let handler: (String, Int) -> Void
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var isListening = false

    public init(handler: @escaping (String, Int) -> Void) {
        self.handler = handler
    }

    public func startListening() {
        guard !isListening else { return }
        isListening = true

        let path = "/tmp/keyflash.sock"
        // Remove any stale socket
        unlink(path)

        // Create Unix domain socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            NSLog("NotificationService: failed to create socket")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, byte) in pathBytes.enumerated() {
                if i < ptr.count { ptr[i] = byte }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr -> Int32 in
                Darwin.bind(socketFD, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("NotificationService: failed to bind socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            return
        }

        // Listen for connections
        guard listen(socketFD, 5) == 0 else {
            NSLog("NotificationService: failed to listen on socket")
            close(socketFD)
            return
        }

        // Read incoming connections
        let src = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        src.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        src.resume()
        self.source = src

        NSLog("NotificationService: listening on \(path)")
    }

    private func acceptConnection() {
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { return }
        // Read a single message (newline-delimited)
        var buf: [UInt8] = [UInt8](repeating: 0, count: 4096)
        let n = read(clientFD, &buf, buf.count)
        close(clientFD)
        guard n > 0 else { return }
        guard let data = String(bytes: buf.prefix(n), encoding: .utf8) else { return }
        let line = data.trimmingCharacters(in: .whitespacesAndNewlines)
        // Format: "agent=claude pid=1234"
        var agent = "unknown"
        var pid = 0
        for part in line.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0] == "agent" { agent = String(kv[1]) }
            if kv[0] == "pid" { pid = Int(kv[1]) ?? 0 }
        }
        NSLog("NotificationService: RECEIVED taskDone — agent=\(agent) pid=\(pid)")
        handler(agent, pid)
    }

    public func stopListening() {
        guard isListening else { return }
        isListening = false
        source?.cancel()
        source = nil
        if socketFD >= 0 { close(socketFD) }
        socketFD = -1
        unlink("/tmp/keyflash.sock")
    }

    deinit { stopListening() }
}
