import Foundation

/// Detects when a coding agent's task is complete by watching for the
/// prompt glyph reappearing in the PTY output after a period of activity.
///
/// Strategy: look for an "idle gap" — the agent outputs continuously during
/// a response, then goes silent when the response is done and the input
/// prompt (`>`, `❯`, `$`, `%`, etc.) appears on a fresh line.
public class PromptDetector {
    private let debug: Bool
    private var sinceLastOutput: Date
    private var gapAccumulator: String
    private var inGap: Bool = false
    private var outputStarted: Bool = false

    /// Known agent prompt markers — ordered from most to least specific.
    private static let agentPrompts: [(pattern: String, name: String)] = [
        ("❯ ", "claude-code"),
        ("❯", "claude-code"),
        (">>> ", "opencode"),
        (">>>", "opencode"),
        ("> ", "generic-prompt"),
        ("$ ", "zsh-prompt"),
        ("% ", "fish-prompt"),
    ]

    /// Minimum quiet time before a prompt pattern signals task completion.
    private let minIdleThreshold: Double = 0.4

    public init(debug: Bool = false) {
        self.debug = debug
        self.sinceLastOutput = Date()
        self.gapAccumulator = ""
    }

    /// Strip ANSI escape sequences from text.
    private func stripANSI(_ text: String) -> String {
        // Matches ESC [ <digits> ; <digits> ... m  (SGR codes)
        // Also ESC ] <text> BEL (OSC codes like title)
        // And other common CSI sequences
        var result = ""
        var inEscape = false
        var inOSC = false
        for char in text {
            if char == "\u{1B}" {
                inEscape = true
                continue
            }
            if inEscape {
                if char == "[" {
                    continue // CSI sequence starts
                } else if char == "]" {
                    inOSC = true
                    inEscape = false
                    continue
                } else {
                    inEscape = false
                    continue
                }
            }
            if inOSC {
                if char == "\u{0007}" || char == "\u{1B}" {
                    inOSC = false
                    if char == "\u{1B}" { inEscape = true }
                }
                continue
            }
            // Control chars except newline/tab
            if char < " " && char != "\n" && char != "\t" { continue }
            result.append(char)
        }
        return result
    }

    /// Feed incoming PTY output data to the detector.
    /// - Returns: `true` if a task completion was detected.
    @discardableResult
    public func feed(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }

        // Strip ANSI escape codes before matching — TUI apps wrap prompts in color codes
        let clean = stripANSI(text)

        let now = Date()
        let gapSinceLast = now.timeIntervalSince(sinceLastOutput)

        // First chunk — just record time, nothing to detect yet
        if !outputStarted {
            outputStarted = true
            sinceLastOutput = now
            return false
        }

        // If we've been idle long enough, accumulate into gap buffer
        if gapSinceLast >= minIdleThreshold {
            inGap = true
            gapAccumulator += clean
        } else if inGap {
            // We were in a gap but output arrived quickly — gap is over
            // Check accumulated gap text before resetting
            if checkAccumulatedGap() {
                return true
            }
            inGap = false
            gapAccumulator = ""
        }

        sinceLastOutput = now

        // Check current chunk for prompt patterns
        if checkForPrompt(in: clean, gapBefore: gapSinceLast) {
            return true
        }

        return false
    }

    /// Check the accumulated gap text for any prompt pattern match.
    private func checkAccumulatedGap() -> Bool {
        for (prompt, name) in Self.agentPrompts {
            if gapAccumulator.contains(prompt) {
                if debug {
                    print("[keyflash] Prompt detector: matched '\(name)' (\(prompt)) in idle gap buffer — TASK COMPLETE")
                }
                gapAccumulator = ""
                inGap = false
                return true
            }
            // Also check if any line has the prompt at the start
            for line in gapAccumulator.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(prompt) || trimmed == prompt.trimmingCharacters(in: .whitespaces) {
                    if debug {
                        print("[keyflash] Prompt detector: matched '\(name)' on gap line '\(trimmed)' — TASK COMPLETE")
                    }
                    gapAccumulator = ""
                    inGap = false
                    return true
                }
            }
        }
        return false
    }

    /// Check a text chunk for prompt patterns.
    private func checkForPrompt(in text: String, gapBefore: TimeInterval) -> Bool {
        for (prompt, name) in Self.agentPrompts {
            guard text.contains(prompt) else { continue }

            // Condition 1: prompt arrived after an idle gap (most reliable)
            if gapBefore >= minIdleThreshold {
                if debug {
                    print("[keyflash] Prompt detector: matched '\(name)' after \(String(format: "%.2f", gapBefore))s gap — TASK COMPLETE")
                }
                return true
            }

            // Condition 2: prompt is on its own line at the end of output
            let lines = text.components(separatedBy: "\n")
            if let lastLine = lines.last {
                let trimmed = lastLine.trimmingCharacters(in: .whitespaces)
                if trimmed == prompt.trimmingCharacters(in: .whitespaces) || trimmed.hasPrefix(prompt) {
                    if debug {
                        print("[keyflash] Prompt detector: matched '\(name)' on last line '\(trimmed)' — TASK COMPLETE")
                    }
                    return true
                }
            }
        }
        return false
    }
}
