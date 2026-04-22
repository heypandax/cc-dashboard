# Architecture

How cc-dashboard is put together internally. If you're just using the app,
[the README](../README.md) is where you want to be. This document is for
contributors and anyone curious about the design.

## Stack

- **Swift 6 + SwiftUI** — UI and main loop. The menu bar uses a hand-rolled
  `NSStatusItem` + `NSPanel` instead of SwiftUI's `MenuBarExtra` — we needed
  control over the popover's auto-hide behavior in pin mode, which
  `MenuBarExtra` does not expose. The main window is a SwiftUI `Window`
  scene.
- **Hummingbird 2.x** + **HummingbirdWebSocket** — embedded HTTP / WebSocket
  server bound to `127.0.0.1:7788`.
- **Swift actor** — `SessionStore` serializes concurrent hook access.
- **UserNotifications** — native system notifications.
- **Sparkle 2.6+** — auto-update with EdDSA-signed appcast.
- **Firebase Analytics + Crashlytics** — anonymous telemetry only; see
  [Privacy](../README.md#privacy).

## HTTP / WebSocket endpoints

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/hook/session-start` · `/pre-tool-use` · `/notification` · `/stop` · `/session-end` | receive Claude CLI hook events |
| POST | `/decision/{id}` | UI submits an approval decision (optionally with `trustMinutes` to open an auto-allow window in the same call) |
| POST | `/trust/{sessionId}` | open auto-allow for a session standalone (body: `{"minutes": N}`) |
| DELETE | `/trust/{sessionId}` | cancel auto-allow |
| GET | `/sessions` · `/approvals` | snapshot queries |
| GET | `/health` | health check |
| WS | `/ws` | real-time event stream: `snapshot` · `session_upsert` · `session_remove` · `session_finished` · `approval_add` · `approval_resolve` · `auto_allow_set` · `auto_allow_cleared` |

## How the hook works

`PreToolUse` intercepts only write-capable tools
(`Bash|Edit|Write|MultiEdit|WebFetch`); read-only tools bypass it.

1. Claude CLI tries to run an intercepted tool.
2. `hooks/pretool.sh` fires, does a 2-second `curl /health` to confirm the
   app is up, then `POST`s to `/hook/pre-tool-use` (waits up to 600s).
3. The server suspends the request and pushes an approval card via
   WebSocket to the UI plus a system notification.
4. User clicks Allow / Allow for N min / Deny → UI calls `/decision/{id}`
   → the server resumes the suspended request.
5. The hook prints `{"hookSpecificOutput":{"permissionDecision":"allow|deny"}}`
   to stdout; Claude CLI proceeds accordingly.
6. If the session is inside an auto-allow window, step 3 is skipped — the
   server returns `allow` immediately.

**No approval timeout**: the server holds the request until the UI decides.
It never auto-denies (this avoids the "I clicked Allow but got denied"
race).

**Fallback path**: if cc-dashboard is not running or hung, the 2s health
check fails and the hook returns `{"permissionDecision":"ask"}` — Claude
Code falls back to its native TUI prompt, so nothing is blocked. If the UI
takes longer than 600s the same fallback kicks in. To extend the window,
bump both `PreToolUse.timeout` in `~/.claude/settings.json` (currently
605s) and `--max-time` in `hooks/pretool.sh` (currently 600s) together.

**Lifecycle hooks** (`SessionStart` / `Stop` / `SessionEnd` /
`Notification`): `hooks/lifecycle.sh` is fire-and-forget, waits at most 3s,
always exits 0 — it never blocks the CLI. Finished sessions disappear from
the UI 10 seconds after completion.

## Where hooks land

On first launch the app copies `hooks/{pretool,lifecycle}.sh` to
`~/Library/Application Support/cc-dashboard/hooks/` and appends matching
entries to `~/.claude/settings.json` (with an automatic timestamped backup
at `settings.json.bak.YYYYMMDD-HHmmss`; existing hooks and other fields are
left untouched). Already installed? Only the scripts are refreshed —
`settings.json` is not modified.

**Script-only setup** (CI, headless machines, don't want to run the app):
use `./install-hooks.sh` manually (requires `jq`). Both paths are
interchangeable — the app recognizes and overwrites entries left by the
shell installer.
