import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Spawns a command under a pseudo-terminal and forwards I/O transparently.
///
/// Uses `posix_spawn` with a manually created PTY (posix_openpt + grantpt +
/// unlockpt). I/O uses `poll()` instead of `select()`/`fd_set` macros (which
/// aren't available in Swift).
///
/// posix_spawn can't make the PTY the child's *controlling terminal*, which
/// Ctrl-C/Ctrl-Z and anything opening `/dev/tty` (git/ssh/sudo prompts) need.
/// So when an `execHelper` binary is given, the child is first started as
/// `<execHelper> __keyflash-pty-exec -- <command...>`; that tiny, freshly
/// exec'd process calls setsid() + TIOCSCTTY and then execvp()s the command
/// (see `runExecHelper`). `keyflash-run` passes its own path.
public class PTYSpawn {
    /// argv[1] marker that puts a binary into exec-helper mode.
    public static let execHelperFlag = "__keyflash-pty-exec"

    public init() {}

    /// Callback invoked when the prompt detector identifies a completed task.
    /// Called from the I/O loop thread — the callback should be lightweight.
    public typealias TaskCompleteCallback = (String) -> Void

    public func run(command: [String],
                    environment: [String: String]? = nil,
                    execHelper: String? = nil,
                    debug: Bool = false,
                    onTaskComplete: TaskCompleteCallback? = nil) -> (exitCode: Int32, detected: Bool) {
        guard !command.isEmpty else { return (127, false) }

        // 1. Open PTY master
        let masterFd = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFd >= 0 else { perror("posix_openpt"); return (-1, false) }

        // 2. Grant access + unlock
        guard grantpt(masterFd) == 0 else { perror("grantpt"); close(masterFd); return (-1, false) }
        guard unlockpt(masterFd) == 0 else { perror("unlockpt"); close(masterFd); return (-1, false) }
        guard let slavePath = slaveName(masterFd) else { close(masterFd); return (-1, false) }

        // 3. Open the slave fd *before* spawning the child
        let slaveFd = open(slavePath, O_RDWR | O_NOCTTY)
        guard slaveFd >= 0 else { perror("open slave"); close(masterFd); return (-1, false) }

        // The child sees a normal, cooked terminal like the one we were started
        // in (echo, ISIG for Ctrl-C, ...). Copy our settings when stdin is a tty.
        var parentTerm = termios()
        if tcgetattr(STDIN_FILENO, &parentTerm) == 0 {
            _ = tcsetattr(slaveFd, TCSANOW, &parentTerm)
        }

        // 4. Set up spawn attributes
        #if canImport(Darwin)
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        #else
        var attr = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // Reset signal handling in the child: we ignore SIGWINCH etc. in this
        // process, and ignored signals would otherwise be inherited.
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for sig in [SIGWINCH, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGPIPE] {
            sigaddset(&defaultSignals, sig)
        }
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)

        var flags = Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        if execHelper == nil {
            // No helper: at least give the child its own session.
            flags |= Int32(spawnSetSID)
        }
        _ = posix_spawnattr_setflags(&attr, Int16(truncatingIfNeeded: flags))

        // 5. Set up file actions: map slave → stdin/stdout/stderr
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
        let fullArgv: [String]
        if let helper = execHelper {
            fullArgv = [helper, Self.execHelperFlag, "--"] + command
        } else {
            fullArgv = command
        }
        let argv: [UnsafeMutablePointer<CChar>?] = fullArgv.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        // Pass the caller's full environment through (PATH, HOME, API keys, TERM,
        // COLORTERM, ...). Only fall back to a TERM value if none is set.
        var env = environment ?? ProcessInfo.processInfo.environment
        if env["TERM"]?.isEmpty ?? true {
            env["TERM"] = "xterm-256color"
        }
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        // 7. Set initial PTY window size from the real terminal
        // Without this, the child starts with 0×0 terminal size → TUI renders in a tiny box
        Self.copyWindowSize(to: masterFd)

        // 8. Spawn! (helper by exact path; plain commands via PATH lookup)
        var childPid = pid_t()
        let spawnErr: Int32 = argv.withUnsafeBufferPointer { argvBuf in
            envp.withUnsafeBufferPointer { envpBuf in
                let argvPtr = UnsafeMutablePointer(mutating: argvBuf.baseAddress!)
                let envpPtr = UnsafeMutablePointer(mutating: envpBuf.baseAddress!)
                if execHelper != nil {
                    return posix_spawn(&childPid, argvBuf[0]!, &actions, &attr, argvPtr, envpPtr)
                }
                return posix_spawnp(&childPid, argvBuf[0]!, &actions, &attr, argvPtr, envpPtr)
            }
        }

        // Close slave in parent (child has its own copy via dup2)
        close(slaveFd)

        guard spawnErr == 0 else {
            fputs("keyflash-run: cannot run \(fullArgv[0]): \(String(cString: strerror(spawnErr)))\n", stderr)
            close(masterFd)
            return (127, false)
        }

        // Set up terminal for raw mode forwarding
        let rawMode = RawMode()
        defer { rawMode.restore() }

        let detector = PromptDetector(debug: debug)
        var childExited = false
        var reaped = false
        var childStatus: Int32 = 0
        var lastDetectedAt: Date = .distantPast  // cooldown: don't re-fire within 1s
        var terminationForwardedAt: Date?        // when we relayed TERM/HUP to the child

        // Signal handling (self-pipe): forward window-size changes to the PTY,
        // and relay termination signals to the child so it exits cleanly — our
        // loop then sees EOF and restores the terminal instead of dying in raw
        // mode. The handler only write()s a byte; the poll loop does the work.
        let signals = SignalPipe(watching: [SIGWINCH, SIGTERM, SIGHUP, SIGINT, SIGQUIT])
        defer { signals?.restore() }

        // Everything is multiplexed in one poll() loop: PTY output, our stdin,
        // and pending signals. (A dispatch/epoll source can't watch /dev/null or a
        // redirected file on Linux, and poll() needs no extra threads or locks.)
        // The master is non-blocking so a child that isn't reading its input can
        // never stop us from draining its output.
        _ = fcntl(masterFd, F_SETFL, fcntl(masterFd, F_GETFL) | O_NONBLOCK)

        var buf = [UInt8](repeating: 0, count: 65536)
        var pendingInput: [UInt8] = []      // typed/piped bytes not yet accepted by the child
        var stdinOpen = true
        var eofSent = 0                     // ^D bytes sent after stdin closed
        var lastEOFSentAt: Date = .distantPast

        while !childExited {
            var pfds = [
                pollfd(fd: masterFd, events: Int16(POLLIN) | (pendingInput.isEmpty ? 0 : Int16(POLLOUT)), revents: 0),
                pollfd(fd: signals?.readFD ?? -1, events: Int16(POLLIN), revents: 0),
                // Backpressure: don't read more input while the child is behind.
                pollfd(fd: (stdinOpen && pendingInput.isEmpty) ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0),
            ]
            let ret = poll(&pfds, nfds_t(pfds.count), 100)  // 100ms timeout

            if ret == -1 {
                if errno == EINTR { continue }
                break
            }

            if ret > 0 && (pfds[1].revents & Int16(POLLIN)) != 0, let signals {
                for sig in signals.drain() {
                    if sig == SIGWINCH {
                        Self.copyWindowSize(to: masterFd)
                    } else {
                        kill(childPid, sig)
                        if sig == SIGTERM || sig == SIGHUP, terminationForwardedAt == nil {
                            terminationForwardedAt = Date()
                        }
                    }
                }
            }

            // Our stdin → child (readable also covers EOF and hangup).
            if ret > 0 && pfds[2].revents != 0 {
                let n = read(STDIN_FILENO, &buf, 4096)
                if n > 0 {
                    pendingInput += buf[0..<n]
                    detector.noteUserInput(buf[0..<n])
                } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    stdinOpen = false   // closed (e.g. piped input ran out)
                }
            }
            flushInput(to: masterFd, pending: &pendingInput)

            // Forward stdin EOF as ^D once all input is delivered. A single ^D can be
            // lost if it arrives before the child is reading (or while it holds a
            // partial line), which would leave it waiting forever, so repeat it a
            // few times while the child is alive.
            if !stdinOpen, pendingInput.isEmpty, eofSent < 6, !reaped,
               eofSent == 0 || Date().timeIntervalSince(lastEOFSentAt) >= 1 {
                var eof: UInt8 = 0x04
                _ = write(masterFd, &eof, 1)
                eofSent += 1
                lastEOFSentAt = Date()
            }

            // We were asked to quit (or our terminal closed) but the agent is
            // ignoring the signal: don't linger forever after the terminal is gone.
            if let asked = terminationForwardedAt, !reaped, Date().timeIntervalSince(asked) > 10 {
                kill(childPid, SIGKILL)
                terminationForwardedAt = nil
            }

            // Child → our stdout
            if ret > 0 {
                let revents = pfds[0].revents
                if (revents & Int16(POLLIN)) != 0 || (revents & Int16(POLLHUP)) != 0 {
                    let n = read(masterFd, &buf, buf.count)
                    if n > 0 {
                        writeAll(STDOUT_FILENO, buf, n)
                        _ = detector.feed(Data(bytes: buf, count: n))
                    } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                        // nothing to read right now
                    } else {
                        childExited = true  // EOF / EIO: child closed the terminal
                    }
                }
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
    public static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }   // WIFEXITED
        if low != 0x7f { return 128 + low }           // WIFSIGNALED
        return 1
    }

    private static func copyWindowSize(to masterFd: Int32) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 || ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &ws) == 0 {
            _ = ioctl(masterFd, UInt(TIOCSWINSZ), &ws)
        }
    }

    // MARK: - Exec helper (runs in the child)

    /// Entry point for exec-helper mode. `args` are the arguments after the
    /// `execHelperFlag` marker: `-- <command> [args...]`. Makes stdin (the PTY
    /// slave) the controlling terminal of a new session, then execs the command.
    /// Only returns control by exiting.
    public static func runExecHelper(_ args: [String]) -> Never {
        var command = args
        if command.first == "--" { command.removeFirst() }
        guard !command.isEmpty else {
            fputs("keyflash-run: missing command\n", stderr)
            exit(127)
        }

        _ = setsid()
        _ = ioctl(STDIN_FILENO, UInt(TIOCSCTTY), 0)

        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        execvp(command[0], argv)

        let err = errno
        fputs("keyflash-run: cannot run \(command[0]): \(String(cString: strerror(err)))\n", stderr)
        exit(err == ENOENT ? 127 : 126)
    }
}

// MARK: - Helpers

#if canImport(Darwin)
private let spawnSetSID = POSIX_SPAWN_SETSID

private func slaveName(_ masterFd: Int32) -> String? {
    guard let name = ptsname(masterFd) else { return nil }
    return String(cString: name)
}
#else
// Glibc hides posix_openpt/grantpt/unlockpt/ptsname and POSIX_SPAWN_SETSID from
// Swift (they need _XOPEN_SOURCE/_GNU_SOURCE). They are thin wrappers over
// /dev/ptmx ioctls, so do the same here.
private let spawnSetSID: Int32 = 0x80
private let TIOCGPTN_: UInt = 0x8004_5430
private let TIOCSPTLCK_: UInt = 0x4004_5431

private func posix_openpt(_ flags: Int32) -> Int32 { open("/dev/ptmx", flags) }
private func grantpt(_ fd: Int32) -> Int32 { 0 } // devpts sets ownership itself
private func unlockpt(_ fd: Int32) -> Int32 {
    var unlock: Int32 = 0
    return ioctl(fd, TIOCSPTLCK_, &unlock)
}
private func slaveName(_ masterFd: Int32) -> String? {
    var n: UInt32 = 0
    guard ioctl(masterFd, TIOCGPTN_, &n) == 0 else { return nil }
    return "/dev/pts/\(n)"
}
#endif

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

/// Writes as much pending input as the (non-blocking) PTY master accepts now.
private func flushInput(to masterFd: Int32, pending: inout [UInt8]) {
    while !pending.isEmpty {
        let n = pending.withUnsafeBytes { write(masterFd, $0.baseAddress, $0.count) }
        if n > 0 {
            pending.removeFirst(n)
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            return  // EAGAIN (child is behind) or the child is gone: try again later
        }
    }
}

/// Write end of the active signal self-pipe (read by the C signal handler).
private var signalPipeWriteFD: Int32 = -1

private let signalPipeHandler: @convention(c) (Int32) -> Void = { sig in
    let savedErrno = errno
    var byte = UInt8(truncatingIfNeeded: sig)
    _ = write(signalPipeWriteFD, &byte, 1)
    errno = savedErrno
}

/// Routes the given signals into a non-blocking pipe while a PTY session runs.
private final class SignalPipe {
    let readFD: Int32
    private let writeFD: Int32
    private var previous: [(Int32, sig_t?)] = []

    init?(watching sigs: [Int32]) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        readFD = fds[0]
        writeFD = fds[1]
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC) // don't leak into the child
        }
        signalPipeWriteFD = writeFD
        for sig in sigs {
            previous.append((sig, signal(sig, signalPipeHandler)))
        }
    }

    /// Returns the signals received since the last call.
    func drain() -> [Int32] {
        var bytes = [UInt8](repeating: 0, count: 64)
        var result: [Int32] = []
        while true {
            let n = read(readFD, &bytes, bytes.count)
            if n <= 0 { break }
            result += bytes[0..<n].map { Int32($0) }
        }
        return result
    }

    func restore() {
        for (sig, handler) in previous { signal(sig, handler) }
        previous.removeAll()
        signalPipeWriteFD = -1
        close(readFD)
        close(writeFD)
    }
}

/// Puts our terminal in raw mode (if stdin is a terminal) and restores it.
private final class RawMode {
    private var original = termios()
    private let active: Bool

    init() {
        guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else {
            active = false
            return
        }
        var raw = original
        cfmakeraw(&raw)
        active = tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0
    }

    func restore() {
        guard active else { return }
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
    }
}
