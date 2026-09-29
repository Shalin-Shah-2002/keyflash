# keyflash roadmap: smart alerts

Two features that build on the native Claude Code / OpenCode hooks:

1. **Different alerts for different events**
2. **Stay quiet when you're already watching**

## 1. Different alerts for different events

Today every event produces the same flash. The agents already tell us *why* they called us, so keyflash should too.

| Event | Source | Flash pattern |
|---|---|---|
| Task finished | Claude `Stop`, OpenCode `session.idle` | Slow, steady pulse |
| Needs you (permission / question) | Claude `Notification`, OpenCode `permission.asked` / `question.asked` | Fast, urgent blink |
| Error | OpenCode `session.error` | Double pulse, repeating |

### Design
- `keyflash-run --notify <agent> [--event done|attention|error]` (default `done`, so existing hooks keep working).
- Socket message becomes `agent=<name> pid=<pid> event=<event>`. `NotifyServer.parse` treats a missing `event` as `done`.
- The OpenCode plugin passes the event; the Claude hooks pass `--event done` (Stop) and `--event attention` (Notification).
- `Backlight.flashArguments` takes a pattern (interval and fade) per event.
- A pending "attention" flash is never downgraded by a later "done".

### Tests
- Parse with and without `event`; unknown values fall back to `done`.
- Hook install writes the right `--event` per hook.
- Plugin sends `attention` for permission/question events.

## 2. Stay quiet when you're watching

Skip the flash when you are clearly already looking at the agent.

### Rule
Do **not** flash when both hold:
- the frontmost app is a terminal or editor (Terminal, iTerm2, Ghostty, kitty, Alacritty, WezTerm, Warp, VS Code, Cursor, JetBrains IDEs), and
- there was keyboard or mouse input within the last N seconds (default 10).

Otherwise flash as usual. "Attention" events use a shorter quiet window, since a blocked agent matters more.

### Design
- `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` checked against a list in config.
- Idle time from `CGEventSource.secondsSinceLastEventType` (already used to stop the flash; no new permission).
- Config keys: `suppressWhenWatching` (default true), `watchingIdleSeconds` (default 10), `terminalBundleIds` (extendable).
- Later: match the agent's own terminal window (needs the tty or pid from the hook) so a different terminal in front doesn't count.

### Tests
- Decision function `shouldFlash(frontmostBundleId:idleSeconds:event:config:)` is pure and unit-tested on Linux CI.
- The AppKit lookup stays a thin wrapper in the app target.

## Later ideas
Skip quick answers (only flash after a minimum task time), quiet hours / Focus mode, a menu bar list of recent completions, phone push when a flash goes unnoticed.
