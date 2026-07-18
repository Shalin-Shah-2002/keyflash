# OpenCode TUI Glitch — Problem & Fix

## The Problem

When running `opencode` (or `claude`) in any terminal — macOS Terminal.app, VS Code integrated terminal, or iTerm2 — the TUI (text user interface) was **rendering only in a tiny box in the top-left corner** instead of filling the full window.

This happened in **every terminal app**, which ruled out terminal-specific issues.

---

## Root Cause

The keyflash project installs wrapper aliases into `~/.zshrc` to monitor when AI coding agents are running (for keyboard backlight notifications):

```bash
# Added automatically by keyflash
alias claude='/Applications/keyflash.app/Contents/MacOS/keyflash-run -- claude'
alias opencode='/Applications/keyflash.app/Contents/MacOS/keyflash-run -- opencode'
alias aider='/Applications/keyflash.app/Contents/MacOS/keyflash-run -- aider'
```

### Why This Breaks TUI Apps

When you type `opencode`, the shell runs `keyflash-run -- opencode` instead of the real binary.

`keyflash-run` launches `opencode` as a **child subprocess**. This breaks the terminal ↔ app communication channel in two ways:

1. **SIGWINCH signals are not passed through** — When the terminal window is resized, the OS sends a `SIGWINCH` (window change) signal to notify apps of the new size. Since `opencode` is a child of `keyflash-run`, it never receives this signal directly, so it never knows the real terminal dimensions.

2. **Terminal size is not inherited correctly** — TUI frameworks (like Bubble Tea used by OpenCode) query the terminal size at startup via `ioctl(TIOCGWINSZ)`. When run through a subprocess wrapper that doesn't properly forward the PTY (pseudo-terminal), this returns 0×0 or a very small size — causing the UI to render in a tiny corner.

---

## Secondary Issues Found (Also Fixed)

### 1. Conflicting ANTHROPIC env vars
These were also in `~/.zshrc`:
```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:3456"
export ANTHROPIC_API_KEY="ollama"
```
These route all Anthropic API calls through a local Ollama proxy at port `3456`. When that proxy is **not running**, Claude Code (used as a sub-agent by OpenCode) would hang on startup — making the glitch worse.

**Fix:** Commented out — only enable when intentionally running the `claude-ollama` alias.

### 2. Missing `$TERM` variable
The `TERM` environment variable was not set early enough in `.zshrc`, so TUI apps could not identify the terminal type.

**Fix:** Added `export TERM=xterm-256color` to `.zshrc`.

---

## The Fix

In `~/.zshrc`, the keyflash wrappers were **commented out**:

```bash
# NOTE: Wrappers disabled — keyflash-run breaks TUI rendering for opencode/claude/aider.
# alias claude='/Applications/keyflash.app/Contents/MacOS/keyflash-run -- claude'
# alias opencode='/Applications/keyflash.app/Contents/MacOS/keyflash-run -- opencode'
# alias aider='/Applications/keyflash.app/Contents/MacOS/keyflash-run -- aider'
```

Now `opencode` and `claude` resolve directly to their real binaries:
- `opencode` → `/Users/shalinshah/.opencode/bin/opencode`
- `claude` → `/opt/homebrew/bin/claude`

---

## Result

✅ `opencode` TUI now fills the full terminal window correctly in all terminals (iTerm2, VS Code, Terminal.app).

---

## Future Fix for keyflash-run

The proper fix inside `keyflash-run` is to use `execvp()` so the process **replaces** keyflash-run in memory instead of being a child subprocess. This preserves all terminal signals and PTY capabilities while still allowing keyflash to hook into the agent lifecycle.

---

*Fixed on: July 18, 2026*
