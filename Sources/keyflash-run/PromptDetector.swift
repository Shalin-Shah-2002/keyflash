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
    private var promptSeen: Bool = false    // set to true after first prompt (skip initial)
    private var outputSinceLastPrompt: Bool = false  // true if Claude output response content since the last prompt

    /// Notify the detector that the user typed something. Called from the stdin reader thread.
    public func noteUserInput() {
        // Mark that user input was provided, so we expect a response to follow.
        // Don't set outputSinceLastPrompt here — only actual PTY output from the
        // agent (not the input echo) should arm the trigger. The input echo itself
        // will arrive as PTY output and will be counted there.
        // However, reset the char counter so previous response chars don't bleed
        // across turns.
        outputCharCount = 0
        outputSinceLastPrompt = false
    }

    /// Known agent prompt markers — ordered from most to least specific.
    ///
    /// IMPORTANT: Only include agent-specific glyphs. Generic patterns like
    /// "> ", "$ ", "% " cause constant false positives because they appear
    /// in tool output, shell commands, and Claude's own prose.
    private static let agentPrompts: [(pattern: String, name: String)] = [
        ("❯\u{00a0}", "claude-code"),   // ❯ + non-breaking space (real TUI output)
        ("❯ ", "claude-code"),           // ❯ + regular space
        ("❯", "claude-code"),           // bare ❯
        (">>> ", "opencode"),            // opencode prompt with space
        (">>>", "opencode"),             // opencode prompt bare
    ]

    /// Minimum quiet time (seconds) before a prompt pattern signals task completion.
    ///
    /// Must be large enough that:
    ///  - Claude Code's post-Enter redraw (❯ → thinking) is ignored  (~0.1s gap)
    ///  - Short one-liner responses followed by prompt are not missed  (>2s silence)
    ///  2.0s means: if Claude outputs *nothing* for 2 full seconds then the
    ///  prompt appears, we treat that as "done". During active generation the
    ///  gap between chunks is well under 2s so it won't fire mid-stream.
    private let minIdleThreshold: Double = 2.0

    /// Minimum number of non-whitespace characters that must have been seen
    /// in the response before we allow a completion trigger.
    /// Prevents firing when Claude redraws the prompt glyph immediately after
    /// the user presses Enter (the redraw produces < 10 chars of PTY output).
    private let minOutputChars: Int = 20

    /// Running count of response content characters seen since the last prompt.
    private var outputCharCount: Int = 0

    public init(debug: Bool = false) {
        self.debug = debug
        self.sinceLastOutput = Date()
        self.gapAccumulator = ""
    }

    /// Strip ANSI escape sequences from text.
    ///
    /// Handles three classes of escape sequence:
    ///   • CSI (Control Sequence Introducer): ESC [ <params> <final byte 0x40-0x7E>
    ///   • OSC (Operating System Command): ESC ] <text> (ST = BEL or ESC \)
    ///   • Single-character escapes: ESC <char>  (e.g. ESC 7 = save cursor)
    ///
    /// The critical fix over the previous implementation is that CSI *parameter
    /// bytes* are now consumed entirely instead of leaking into the output text.
    /// Without this, `ESC[1G❯ ESC[0m` would become `1G❯ 0m` instead of `❯  `,
    /// breaking prompt-on-standalone-line detection.
    private func stripANSI(_ text: String) -> String {
        // Per ECMA-48 / VT100, a CSI sequence is:
        //   ESC [ 0x40-0x7E  OR  ESC [ <parameter bytes 0x20-0x3F>* <intermediate bytes 0x20-0x2F>* <final byte 0x40-0x7E>
        // We simplify: skip everything from `ESC[` until a byte in 0x40-0x7E, then stop.
        var result = ""
        var inEscape = false    // true between ESC and the next char
        var inCSI = false       // true from ESC[ until the CSI final byte
        var inOSC = false       // true from ESC] until BEL or ESC
        for char in text {
            let ch = char.asciiValue ?? 0

            // --- Start detection ---
            if ch == 0x1B { // ESC
                inEscape = true
                continue
            }

            // --- After ESC, determine sequence type ---
            if inEscape {
                inEscape = false
                switch char {
                case "[":
                    inCSI = true
                case "]":
                    inOSC = true
                default:
                    // Single-char escape (ESC X) — skip one character, done
                    break
                }
                continue
            }

            // --- In a CSI sequence: skip until final byte (0x40-0x7E) ---
            if inCSI {
                if ch >= 0x40 && ch <= 0x7E {
                    inCSI = false
                }
                continue
            }

            // --- In an OSC sequence: skip until ST (BEL=0x07 or ESC \) ---
            if inOSC {
                if ch == 0x07 {
                    inOSC = false
                } else if ch == 0x1B {
                    inOSC = false
                    // Next char is the '\' of ST (ESC \) — consume it
                    // by leaving inEscape false; the \ will be skipped by
                    // the control-char check below.
                }
                continue
            }

            // --- Regular character ---
            // Control characters except newline and tab
            if ch < 0x20 && ch != 0x0A && ch != 0x09 { continue }
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

        // Track whether the agent produced real response content since the last prompt.
        //
        // We consider content "real" when the clean text contains non-whitespace
        // content that is not *solely* one of the known prompt markers (❯, >>>, >, $, %).
        // This handles:
        //   - Prose and code (has letters/digits)
        //   - Symbol-only output like `$ !@#$`  (has non-whitespace beyond the prompt)
        //   - Pure number output like `42`
        //
        // "Prompt only" chunks (e.g. TUI redrawing `❯ ` after a resize) correctly
        // do NOT set this flag, avoiding false-positive detection.
        if promptSeen {
            let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let isOnlyPromptMarker = Self.agentPrompts.contains { p, _ in
                    // Compare against the prompt pattern with the same trimming
                    trimmed == p.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !isOnlyPromptMarker {
                    outputSinceLastPrompt = true
                    // Accumulate non-prompt content length for the minOutputChars guard
                    outputCharCount += trimmed.count
                }
            }
        }

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
        // Must have seen real response output before the gap began
        guard outputSinceLastPrompt else { return false }
        // Must have accumulated enough content to rule out a prompt redraw
        guard outputCharCount >= minOutputChars else {
            if debug { print("[keyflash] Prompt detector: gap check skipped — only \(outputCharCount) chars seen (need \(minOutputChars))") }
            return false
        }

        for (prompt, name) in Self.agentPrompts {
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespaces)
            if trimmedPrompt.isEmpty { continue }

            // Check if the gap buffer contains the exact prompt
            if gapAccumulator.contains(trimmedPrompt) {
                if debug {
                    print("[keyflash] Prompt detector: matched '\(name)' (\(prompt)) in idle gap buffer — TASK COMPLETE (outputChars=\(outputCharCount))")
                }
                gapAccumulator = ""
                inGap = false
                outputSinceLastPrompt = false
                outputCharCount = 0
                return true
            }
            // Also check if any line in the gap buffer is exactly the prompt
            for line in gapAccumulator.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == trimmedPrompt {
                    if debug {
                        print("[keyflash] Prompt detector: matched '\(name)' on gap line '\(trimmed)' — TASK COMPLETE (outputChars=\(outputCharCount))")
                    }
                    gapAccumulator = ""
                    inGap = false
                    outputSinceLastPrompt = false
                    outputCharCount = 0
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

            // On first ever prompt match (claude just opened) — record it, don't trigger
            if !promptSeen {
                promptSeen = true
                outputSinceLastPrompt = false  // reset: no response content seen yet
                outputCharCount = 0
                if debug { print("[keyflash] Prompt detector: initial prompt seen, arming") }
                continue
            }

            // Must have seen real response output since the last prompt,
            // otherwise this is just a stray marker during startup/shutdown.
            guard outputSinceLastPrompt else {
                if debug { print("[keyflash] Prompt detector: prompt seen but no output since last prompt, skipping") }
                continue
            }

            // Must have accumulated enough output chars to rule out a prompt redraw.
            // After Enter, Claude Code redraws ❯  almost instantly with ~5-10 chars.
            // A real response is always >> 50 chars.
            guard outputCharCount >= minOutputChars else {
                if debug { print("[keyflash] Prompt detector: prompt seen but only \(outputCharCount) chars (need \(minOutputChars)), skipping") }
                continue
            }

            // Reset for the next turn — we're about to fire the notification
            outputSinceLastPrompt = false
            outputCharCount = 0

            // Condition 1: prompt arrived after an idle gap (most reliable)
            // With minIdleThreshold=2.0s this means the agent was completely
            // silent for 2s before the prompt appeared — a very reliable signal.
            if gapBefore >= minIdleThreshold {
                if debug {
                    print("[keyflash] Prompt detector: matched '\(name)' after \(String(format: "%.2f", gapBefore))s gap — TASK COMPLETE (outputChars=\(outputCharCount))")
                }
                return true
            }

            // Condition 2: prompt is the very last thing on its own line
            // (handles cases where the prompt arrives in the same chunk as the
            //  last line of output without a preceding gap)
            let lines = text.components(separatedBy: "\n")
            if let lastNonEmptyLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let trimmedPrompt = prompt.trimmingCharacters(in: .whitespaces)
                let trimmedLine = lastNonEmptyLine.trimmingCharacters(in: .whitespaces)
                if trimmedLine == trimmedPrompt {
                    if debug {
                        print("[keyflash] Prompt detector: matched '\(name)' on standalone last line — TASK COMPLETE")
                    }
                    return true
                }
            }
        }
        return false
    }
}
