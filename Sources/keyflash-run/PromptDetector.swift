import Foundation

/// Detects when a wrapped agent's task is complete: the user submitted a prompt
/// (pressed Enter), the agent produced output, and then went quiet.
///
/// This is only a fallback for agents without native hooks (e.g. aider).
/// Claude Code and OpenCode report completion exactly via `AgentHooks`.
///
/// Thread-safe: `noteUserInput` is called from the stdin queue while `feed` and
/// `checkIdleSilence` run on the PTY loop thread.
public class PromptDetector {
    private let debug: Bool
    private let lock = NSLock()

    /// A prompt was submitted and we're waiting for its response to finish.
    private var awaitingResponse: Bool = false
    /// Output that could be a response has arrived since the prompt was submitted.
    private var hasOutputSinceSubmit: Bool = false
    private var lastOutputTime: Date = .distantPast
    private var lastInputTime: Date = .distantPast

    /// Silence threshold in seconds before declaring a response complete.
    private let silenceThreshold: TimeInterval = 1.5

    /// Output arriving this soon after a keystroke is treated as the terminal
    /// echoing/redrawing that keystroke, not as the agent's response.
    private let echoWindow: TimeInterval = 0.25

    public init(debug: Bool = false) {
        self.debug = debug
    }

    /// Called with the bytes the user typed into STDIN.
    ///
    /// Only Enter (CR/LF) arms detection, so pausing while typing a prompt no
    /// longer looks like "output followed by silence".
    public func noteUserInput<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        let submitted = bytes.contains { $0 == 0x0D || $0 == 0x0A }
        lock.lock()
        lastInputTime = Date()
        if submitted {
            awaitingResponse = true
            hasOutputSinceSubmit = false
        }
        lock.unlock()
        if submitted && debug { writeLog("[PromptDetector] User submitted prompt (Enter)") }
    }

    /// Called whenever data is read from the PTY master (agent stdout/stderr).
    @discardableResult
    public func feed(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let now = Date()
        lock.lock()
        lastOutputTime = now
        if awaitingResponse && now.timeIntervalSince(lastInputTime) > echoWindow {
            hasOutputSinceSubmit = true
        }
        lock.unlock()
        return false
    }

    /// Called periodically by the I/O poll loop (every ~100ms).
    /// Returns `true` once per submitted prompt when its response has completed.
    public func checkIdleSilence() -> Bool {
        lock.lock()
        guard awaitingResponse && hasOutputSinceSubmit else {
            lock.unlock()
            return false
        }
        let silence = Date().timeIntervalSince(lastOutputTime)
        let done = silence >= silenceThreshold
        if done {
            // Task complete! Reset state for the next prompt.
            awaitingResponse = false
            hasOutputSinceSubmit = false
        }
        lock.unlock()

        if done && debug {
            writeLog("[PromptDetector] Response complete (\(String(format: "%.2f", silence))s silence after response output) — TASK COMPLETE")
        }
        return done
    }
}
