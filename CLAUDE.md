# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS 14+ menu bar app (Swift 6 / SwiftUI) that intercepts `PreToolUse` hooks
from concurrent Claude Code sessions and surfaces their approval prompts in a
single UI. Also handles lifecycle events and per-session time-boxed
auto-allow windows. See `README.md` for user-facing docs, `docs/architecture.md`
for the design, and `CONTRIBUTING.md` for coding style / local setup.

## Build + run

```bash
swift package resolve                       # first time only
CC_SIGN_IDENTITY=- ./make-bundle.sh         # ad-hoc local build (no Developer ID needed)
./make-bundle.sh                            # Developer ID signed
CC_NOTARIZE=1 ./make-bundle.sh              # notarized DMG (prod release path)
open dist/cc-dashboard.app
```

`make-bundle.sh` is not a thin wrapper — it does icon compile (`actool` on
`design/AppIcon.icon`), localized resource copy, hook script embed, Sparkle
framework embed, layered codesigning (Sparkle inner → main app; **never
`--deep`**, which would stomp Sparkle's entitlements), and optional notarize /
staple. Build config lives here, not in `Package.swift`.

**Firebase is optional for local dev.** Without a `GoogleService-Info.plist`
at the repo root, `Telemetry.configure()` calls `FirebaseApp.configure()`
which refuses to start. Either drop in a plist from your own Firebase project
or comment out `Telemetry.configure()` in `App.swift` while iterating.

## Tests

```bash
swift test --parallel            # all tests; no .app bundle needed
swift test --filter SessionStoreTests
swift test --filter SessionStoreTests.testAutoAllowExpires
```

`SessionStore` accepts injected `now: () -> Date` and `delay: (UInt64) async -> Void`
closures. Tests pass in `TestScheduler` (`Tests/.../Support/TestScheduler.swift`)
so `auto-allow` expiry and `session purge` timers fast-forward via
`scheduler.advance(bySeconds:)` instead of real `sleep`. When adding a new
time-dependent code path in `SessionStore`, route it through `now()` / `delay()`,
not `Date()` / `Task.sleep` directly — otherwise tests will become flaky and slow.

Fixtures under `Tests/CCDashboardTests/Fixtures` are copied via
`resources: [.copy("Fixtures")]` in `Package.swift`.

## Architecture, the 30-second version

```
Claude CLI  ──hook──▶  hooks/pretool.sh  ──HTTP──▶  Hummingbird on 127.0.0.1:7788
                                                      │
                                                      ▼
                                                 SessionStore (actor)
                                                 │ pending approvals  ◀── WebSocket ── UI (SwiftUI)
                                                 │ auto-allow windows
                                                 └──CheckedContinuation resumed by /decision/{id}
                                                                │
Claude CLI ◀── stdout JSON {allow|deny|ask} ◀── hook process ◀─┘
```

Four moving parts; none of them is discoverable by reading a single file:

1. **Hook wrappers are fail-safe by design** (`hooks/pretool.sh`,
   `hooks/lifecycle.sh`). `pretool.sh` does a 2-second `/health` probe first
   and falls back to `{"permissionDecision":"ask"}` if cc-dashboard is not
   running. That fallback routes to Claude's native TUI prompt, so the CLI
   is never blocked by this app crashing or being quit. Lifecycle hooks are
   fire-and-forget with a 3-second timeout, always exit 0.

2. **`SessionStore` is an `actor` and the single source of truth.** HTTP
   handlers and UI (MainActor) both serialize through it. `requestApproval`
   suspends on a `CheckedContinuation` and only resumes when
   `resolveApproval(id:)` is called by the UI — **there is no server-side
   timeout**. The 600s cap lives in the shell wrapper, not here. If you add
   a code path that could lose a continuation, approvals will hang forever.

3. **`Task.sleep(nanoseconds:)` not `Clock.sleep(for:)` / `Task.sleep(for:)`.**
   The `Clock`-based variants trigger `swift_task_dealloc` abort on the
   macOS 26 cooperative pool (see fix in commit `fffadbc`). Don't "modernize"
   the timer code in `SessionStore.swift` without reading that commit first.

4. **Two timeouts must stay paired.** `PreToolUse.timeout` in
   `~/.claude/settings.json` (currently 605s) must exceed `--max-time` in
   `hooks/pretool.sh` (600s). `HooksInstaller.appendCCDashboard` and
   `install-hooks.sh` both write these; change both if you change either.

## Source layout

```
Sources/CCDashboard/
├── App.swift                    SwiftUI entry; AppState.shared wires Dashboard + StatusBar
├── Core/
│   ├── SessionStore.swift       Actor state hub; approvals, sessions, auto-allow, event stream
│   ├── Models.swift             HookInput/Output, ApprovalRequest, AnyCodable, DashboardEvent
│   ├── HooksInstaller.swift     Idempotent merge into ~/.claude/settings.json on first launch
│   ├── Telemetry.swift          Firebase Analytics + Crashlytics (only typed enum keys)
│   └── Log.swift                os.Logger; subsystem "com.heypanda.cc-dashboard"
├── Server/
│   ├── HTTPServer.swift         Hummingbird router: /hook/* /decision/* /trust/* /sessions /approvals /ws
│   └── HookHandlers.swift       Bridges HTTP to SessionStore (async)
└── UI/
    ├── Dashboard.swift          @MainActor @Observable ViewModel; subscribes to SessionStore stream
    ├── StatusBarController.swift Hand-rolled NSStatusItem + NSPanel (not MenuBarExtra)
    ├── MenuBarView.swift / ApprovalCard.swift / MainWindow.swift / Sidebar.swift
    ├── Notifier.swift           UserNotifications
    └── Tokens.swift             The CC enum — all colors / fonts / spacing go through it
```

### Design decisions you'll trip over

- **Not `MenuBarExtra`.** `StatusBarController` hand-rolls `NSStatusItem` +
  `NSPanel` because the pin-mode (panel stays open across Space / fullscreen
  switches, closes only on outside click) needs control over
  `hidesOnDeactivate` that `MenuBarExtra` doesn't expose.
- **Design tokens go through `CC` in `UI/Tokens.swift`.** No raw `Color(hex:)`,
  no inline padding, no new fonts. Dark-mode adaptive variants use
  `Color(light:dark:)` backed by an `NSColor` dynamic provider.
- **Telemetry only uploads enum cases.** Add to `Telemetry.Event` and
  `Telemetry.Key`; never pass raw strings. Never upload command strings, file
  paths, cwds, or tool input contents — the README and privacy policy commit
  to that, and it's enforced by review.
- **Localization is two files.** Any user-facing string needs an entry in both
  `Resources/en.lproj/Localizable.strings` (source of truth) and
  `Resources/zh-Hans.lproj/Localizable.strings`. SwiftUI `Text("…")` literals
  are already `LocalizedStringKey`; for runtime-built strings use
  `String(localized: "…")` (see `Notifier.swift`).

## Release

GitHub Actions `release.yml` (workflow_dispatch with version input) is the
canonical path: it bumps `Info.plist`, builds signed + notarized DMG on
macos-26, updates `docs/appcast.xml` (Sparkle) and
`homebrew-cask/Casks/cc-dashboard.rb`, tags, creates a GitHub release, and
syncs the tap at `heypandax/homebrew-cc-dashboard`. Do not manually edit the
appcast or cask; `scripts/update_appcast.sh` regenerates them.

## Commit authoring — hard rules

These exist because past sessions violated them and the fallout required a
`git filter-repo` + history wipe to clean up. No exceptions.

1. **Always override identity inline, every commit.** The ambient
   `user.email` in this machine's global git config is `panda@hellotalk.cn`
   — a work address, wrong for this personal OSS project. Committing under
   it splits the GitHub contributor graph across two identities and leaks
   a work email into public history. Every commit you make on my behalf:

   ```bash
   git -c user.email=pandaleecn@gmail.com -c user.name="Panda Lee" \
       commit -m "..."
   ```

   Never `git config --global user.email ...` — do not modify the config
   file. Override per-invocation only, so HelloTalk work repos keep their
   own identity.

2. **Never add `Co-Authored-By: Claude …` trailers.** Not as a default,
   not as a convention, not even when an upstream commit template suggests
   it. GitHub parses the trailer into a contributor attribution and it
   then appears in Insights → Contributors. Removing it retroactively
   requires rewriting history and force-pushing `main` — which is rule 3.

   If I ever explicitly ask to attribute Claude in a specific commit, do
   it for that commit only. Default is no co-author lines, period.

3. **Force-push to main is gated on explicit per-incident authorization.**
   "The user said yes once" does not cover the next push. Warn, pause,
   and wait every time. This reinforces the global rule — it is not
   relaxed by anything in this file.

4. **Match commit scope to the change.** Don't bundle unrelated edits
   (e.g. a CI runner bump riding into a README commit). Separate commits
   per theme so history stays bisectable.

## Two identifiers, not a typo

- `com.heypanda.cc-dashboard` — bundle ID / LaunchAgent label / UserDefaults
  domain / `os.Logger` subsystem. Changing it orphans every install's state
  (auto-allow windows, opt-out flag). Pinned for the life of the project.
- `heypandax` — GitHub handle; used in repo URLs, Homebrew tap, appcast host.

They live in different ecosystems. Do not rename one "to match" the other.

## Conventions (applied, not just aspirational)

- Comments explain **why**, never what. Delete anything that narrates the
  diff. Keep comments that record non-obvious constraints or cite past
  commits (`// see commit fffadbc`).
- Don't add error handling for scenarios that can't happen — trust internal
  contracts, only validate at system boundaries (hook input, HTTP request
  body, user input). `riskLevel(for:)` is deliberately heuristic, not
  exhaustive.
- User-visible changes need a line under `[Unreleased]` in `CHANGELOG.md`.
  Plumbing-only changes don't.
