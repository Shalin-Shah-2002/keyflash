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

        // Run the child in its own session (setflags replaces, so set once).
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

        // Pass the caller's full environment through (PATH, HOME, API keys, TERM,
        // COLORTERM, ...). Only fall back to a TERM value if none is set.
        var env = environment ?? ProcessInfo.processInfo.environment
        if env["TERM"]?.isEmpty ?? true {
            env["TERM"] = "xterm-256color"
        }
        let envBuilder = env.map { "\($0.key)=\($0.value)" }
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
        var childExited = false
        var reaped = false
        var childStatus: Int32 = 0
        var lastDetectedAt: Date = .distantPast  // cooldown: don't re-fire within 1s

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

        // Background stdin reader (serial queue; PromptDetector is internally locked)
        var stdinBuf = [UInt8](repeating: 0, count: 4096)
        let stdinQueue = DispatchQueue(label: "keyflash.stdin")
        let stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: stdinQueue)
        stdinSource.setEventHandler {
            let n = read(STDIN_FILENO, &stdinBuf, stdinBuf.count)
            if n > 0 {
                writeAll(masterFd, stdinBuf, n)
                detector.noteUserInput(stdinBuf[0..<n])
            } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                // stdin closed (e.g. piped input ran out): forward EOF (^D) to the
                // child and stop watching, otherwise this handler spins forever.
                var eof: UInt8 = 0x04
                _ = write(masterFd, &eof, 1)
                stdinSource.cancel()
            }
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
                        writeAll(STDOUT_FILENO, buf, n)
                        _ = detector.feed(Data(bytes: buf, count: n))
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        childExited = true  // EOF / EIO: child closed the terminal
                    }
                }
            } else if ret == -1 {
                if errno == EINTR { continue }
                childExited = true
            }

            // Check if response completed and went silent
            if detector.checkIdleSilence() {
                let now = Date()
                if now.timeIntervalSince(lastDetectedAt) > 1.0 {
                    lastDetectedAt = now
                    onTaskComplete?(command[0])
                }
            }

            // Non-blocking child status check
            if !reaped {
                var wstatus: Int32 = 0
                if waitpid(childPid, &wstatus, WNOHANG) == childPid {
                    childStatus = wstatus
                    reaped = true
                    childExited = true
                }
            }
        }

        // Drain any output still buffered in the PTY (non-blocking).
        var drainPfd = pollfd(fd: masterFd, events: Int16(POLLIN), revents: 0)
        while poll(&drainPfd, 1, 0) > 0 {
            let n = read(masterFd, &buf, buf.count)
            if n > 0 { writeAll(STDOUT_FILENO, buf, n) } else { break }
        }

        // The PTY reaching EOF usually beats waitpid(WNOHANG); always collect the
        // real exit status so the agent's exit code isn't lost.
        if !reaped {
            var wstatus: Int32 = 0
            while waitpid(childPid, &wstatus, 0) == -1 && errno == EINTR {}
            childStatus = wstatus
        }

        close(masterFd)
        let exitCode = Self.exitCode(fromWaitStatus: childStatus)
        let anyDetection = lastDetectedAt != .distantPast
        return (exitCode, anyDetection)
    }

    /// Shell-style exit code: WEXITSTATUS for normal exits, 128+signal when killed.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }   // WIFEXITED
        if low != 0x7f { return 128 + low }           // WIFSIGNALED
        return 1
    }
}

/// write(2) until every byte is written (handles partial writes and EINTR).
private func writeAll(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) {
    var offset = 0
    while offset < count {
        let n = write(fd, bytes + offset, count - offset)
        if n > 0 {
            offset += n
        } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
            continue
        } else {
            return
        }
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
