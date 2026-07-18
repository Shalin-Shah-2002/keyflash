import Foundation
import Darwin

/// Spawns a command under a pseudo-terminal and forwards I/O transparently.
///
/// Uses `posix_spawnp` (modern macOS process spawning) with a manually
/// created PTY (posix_openpt + grantpt + unlockpt). I/O uses `poll()`
/// instead of `select()`/`fd_set` macros (which aren't available in Swift).
public class PTYSpawn {
    public struct Result {
        public let exitCode: Int32
        public let taskCompleted: Bool
    }

    public init() {}

    /// Callback invoked when the prompt detector identifies a completed task.
    /// Called from the I/O loop thread — the callback should be lightweight.
    public typealias TaskCompleteCallback = (String) -> Void

    public func run(command: [String],
                    environment: [String: String]? = nil,
                    debug: Bool = false,
                    onTaskComplete: TaskCompleteCallback? = nil) -> (exitCode: Int32, detected: Bool) {
        // 1. Open PTY master
        let masterFd = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFd >= 0 else { perror("posix_openpt"); return (-1, false) }

        // 2. Grant access + unlock
        guard grantpt(masterFd) == 0 else { perror("grantpt"); close(masterFd); return (-1, false) }
        guard unlockpt(masterFd) == 0 else { perror("unlockpt"); close(masterFd); return (-1, false) }
        guard let slavePath = ptsname(masterFd) else { close(masterFd); return (-1, false) }

        // 3. Open the slave fd *before* spawning the child
        let slaveFd = open(slavePath, O_RDWR)
        guard slaveFd >= 0 else { perror("open slave"); close(masterFd); return (-1, false) }

        // 4. Set up spawn attributes
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // Set the process group to the child's PID so it becomes a session leader
        posix_spawnattr_setpgroup(&attr, 0) // 0 = use child PID as group
        _ = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

        // Set the controlling terminal
        _ = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        // 5. Set up file actions: map slave → stdin/stdout/stderr
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_adddup2(&actions, slaveFd, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slaveFd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slaveFd, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, masterFd)
        if slaveFd > 2 {
            posix_spawn_file_actions_addclose(&actions, slaveFd)
        }

        // 6. Build argv + environment
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var envBuilder: [String] = []
        if let env = environment {
            envBuilder = env.map { "\($0.key)=\($0.value)" }
        }
        // Add TERM if not present
        if environment?["TERM"] == nil {
            envBuilder.append("TERM=xterm-256color")
        }
        let envp: [UnsafeMutablePointer<CChar>?] = envBuilder.map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }

        // 7. Set initial PTY window size from the real terminal
        // Without this, the child starts with 0×0 terminal size → TUI renders in a tiny box
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
            _ = ioctl(masterFd, TIOCSWINSZ, &ws)
        }

        // 8. Spawn!
        var childPid: pid_t = 0
        let spawnErr = argv.withUnsafeBufferPointer { argvBuf in
            envp.withUnsafeBufferPointer { envpBuf in
                posix_spawnp(&childPid, argvBuf[0], &actions, &attr,
                             UnsafeMutablePointer(mutating: argvBuf.baseAddress),
                             UnsafeMutablePointer(mutating: envpBuf.baseAddress))
            }
        }

        // Close slave in parent (child has its own copy via dup2)
        close(slaveFd)

        guard spawnErr == 0 else {
            perror("posix_spawnp")
            close(masterFd)
            return (-1, false)
        }

        // Set up terminal for raw mode forwarding
        var origTerm = enableRawMode()
        defer { restoreRawMode(&origTerm) }

        let detector = PromptDetector(debug: debug)
        var detected = false
        var childExited = false
        var childStatus: Int32 = 0

        // SIGWINCH handler — forward terminal size changes to child PTY
        // Need to call sigaction() first so DispatchSource can intercept the signal
        var sa = sigaction()
        sa.__sigaction_u.__sa_handler = SIG_IGN
        sigaction(SIGWINCH, &sa, nil)
        let winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH)
        winchSource.setEventHandler {
            var ws = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
                _ = ioctl(masterFd, TIOCSWINSZ, &ws)
            }
        }
        winchSource.resume()
        defer { winchSource.cancel() }

        // Background stdin reader
        var stdinBuf = [UInt8](repeating: 0, count: 4096)
        let stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO)
        stdinSource.setEventHandler {
            let n = read(STDIN_FILENO, &stdinBuf, stdinBuf.count)
            if n > 0 { write(masterFd, stdinBuf, n) }
        }
        stdinSource.resume()
        defer { stdinSource.cancel() }

        // Main read loop using poll()
        var buf = [UInt8](repeating: 0, count: 65536)
        var pfd = pollfd(fd: masterFd, events: Int16(POLLIN), revents: 0)

        while !childExited {
            let ret = poll(&pfd, 1, 100)  // 100ms timeout

            if ret > 0 {
                if (pfd.revents & Int16(POLLIN)) != 0 || (pfd.revents & Int16(POLLHUP)) != 0 {
                    let n = read(masterFd, &buf, buf.count)
                    if n > 0 {
                        write(STDOUT_FILENO, buf, n)
                        if !detected {
                            if detector.feed(Data(bytes: buf, count: n)) {
                                detected = true
                                onTaskComplete?(command[0])
                            }
                        }
                    } else {
                        childExited = true  // EOF
                    }
                }
            } else if ret == -1 {
                if errno == EINTR { continue }
                childExited = true
            }

            // Non-blocking child status check
            var wstatus: Int32 = 0
            if waitpid(childPid, &wstatus, WNOHANG) == childPid {
                childStatus = wstatus
                childExited = true
            }
        }

        // If detected but child alive, keep forwarding until exit
        if detected && !childDidExit(childStatus) {
            var buf2 = [UInt8](repeating: 0, count: 65536)
            var pfd2 = pollfd(fd: masterFd, events: Int16(POLLIN), revents: 0)
            while true {
                let s = poll(&pfd2, 1, 500)
                if s > 0 {
                    let n = read(masterFd, &buf2, buf2.count)
                    if n > 0 { write(STDOUT_FILENO, buf2, n) } else { break }
                }
                var wstatus: Int32 = 0
                if waitpid(childPid, &wstatus, WNOHANG) == childPid {
                    childStatus = wstatus
                    break
                }
            }
        }

        close(masterFd)
        let exitCode = (childStatus & 0xFF00) >> 8
        return (exitCode, detected)
    }

    private func childDidExit(_ status: Int32) -> Bool {
        // WIFEXITED(x): ((x) & 0x7f) == 0
        // WIFSIGNALED(x): ((x) & 0x7f) != 0 && ((x) & 0x7f) != 0x7f
        let ws = status & 0x7f
        return ws == 0 || (ws != 0 && ws != 0x7f)
    }
}

// MARK: - Terminal raw mode

private func enableRawMode() -> termios {
    var term = termios()
    tcgetattr(STDIN_FILENO, &term)
    var raw = term
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    return term
}

private func restoreRawMode(_ original: inout termios) {
    tcsetattr(STDIN_FILENO, TCSANOW, &original)
}
