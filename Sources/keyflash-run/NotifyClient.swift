import Foundation
import Darwin

/// Sends task-completion notifications to the keyflash menu bar app.
///
/// Uses a Unix domain socket at `/tmp/keyflash.sock` because
/// `DistributedNotificationCenter` is unreliable for unsigned apps on macOS 26.
public struct NotifyClient {
    public static func sendDone(agent: String, pid: Int) {
        let path = "/tmp/keyflash.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            writeLog("NotifyClient: failed to create socket: \(String(cString: strerror(errno)))")
            return
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, byte) in pathBytes.enumerated() {
                if i < ptr.count { ptr[i] = byte }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr -> Int32 in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            writeLog("NotifyClient: failed to connect to socket: \(String(cString: strerror(errno)))")
            return
        }

        // Send a newline-delimited message: "agent=claude pid=1234\n"
        let message = "agent=\(agent) pid=\(pid)\n"
        _ = message.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
        writeLog("NotifyClient: sent taskDone to /tmp/keyflash.sock")
    }
}
