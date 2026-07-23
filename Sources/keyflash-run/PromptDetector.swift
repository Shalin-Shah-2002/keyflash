import Foundation

/// Detects when a coding agent's task is complete by tracking user input vs response output,
/// combined with a quiet silence period (idle gap) after the response finishes.
public class PromptDetector {
    private let debug: Bool
    private var userActive: Bool = false
    private var hasOutputSinceInput: Bool = false
    private var lastOutputTime: Date = .distantPast

    /// Silence threshold in seconds before declaring a response complete.
    /// When Claude Code is generating output or running tools, output arrives continuously.
    /// When it finishes the current turn and waits for the user's next prompt, output stops.
    private let silenceThreshold: TimeInterval = 1.5

    public init(debug: Bool = false) {
        self.debug = debug
    }

    /// Called when user types into STDIN.
    public func noteUserInput() {
        userActive = true
        hasOutputSinceInput = false
        if debug { writeLog("[PromptDetector] User submitted prompt (stdin input detected)") }
    }

    /// Called whenever data is read from the PTY master (agent stdout/stderr).
    @discardableResult
    public func feed(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        
        lastOutputTime = Date()
        
        if userActive {
            hasOutputSinceInput = true
        }

        return false
    }

    /// Called periodically by the I/O poll loop (every ~100ms).
    /// Returns `true` if a response completion is detected.
    public func checkIdleSilence() -> Bool {
        guard userActive && hasOutputSinceInput else { return false }

        let silence = Date().timeIntervalSince(lastOutputTime)
        if silence >= silenceThreshold {
            // Task complete! Reset state for next interaction turn.
            userActive = false
            hasOutputSinceInput = false
            if debug {
                writeLog("[PromptDetector] Response complete (\(String(format: "%.2f", silence))s silence after response output) — TASK COMPLETE")
            }
            return true
        }

        return false
    }
}
