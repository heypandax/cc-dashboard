# Changelog

All notable changes to cc-dashboard are documented here. The format is based
on [Keep a Changelog][kac], and this project adheres to [Semantic
Versioning][semver].

[kac]: https://keepachangelog.com/en/1.1.0/
[semver]: https://semver.org/spec/v2.0.0.html

## [Unreleased]

### Changed
- Starting a trust window now also approves any already-pending approvals
  for that session, matching the user intent that "I trust this session"
  should cover the request currently waiting, not just future ones.

### Fixed
- Row-level trust popover no longer vanishes when the cursor moves from
  the hover-revealed clock button onto the popover options. The button
  now stays mounted while the popover is open.

## [0.1.2] — 2026-04-23

### Added
- Rename sessions inline (double-click the name) or via the row context menu.
  Aliases are keyed by cwd and persisted in `UserDefaults` under
  `sessionAliases`, so reopening a project auto-restores the name. When no
  alias is set the row falls back to the first 8 characters of the session id.
- Row-level auto-trust: hover a session to reveal a clock icon that opens a
  2 / 10 / 30-minute trust picker, or use the context menu — no waiting for
  the next approval to set a window.
- Firebase Analytics + Crashlytics integration (anonymous events only — never
  command content, file paths, or cwd). Opt out via `defaults write
  com.heypanda.cc-dashboard analyticsEnabled 0`.
- Localization: English (source) and Simplified Chinese (`zh-Hans`).
- Test suite (`Tests/CCDashboardTests/`): `SessionStore` with injected `now` /
  `delay` seams, `HooksInstaller` settings merge, Codable contract round-trips,
  HTTP/WebSocket integration via `HummingbirdTesting`.
- GitHub Actions CI (`test.yml`) — `swift test` on every push/PR.
- GitHub Actions release workflow (`release.yml`) — build, sign, notarize,
  staple, upload DMG, update appcast + Homebrew Cask tap atomically.
- `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`,
  issue/PR templates.

### Changed
- App display name is now "CC Dashboard" (`CFBundleDisplayName` +
  `CFBundleName`). Bundle identifier stays `com.heypanda.cc-dashboard` for
  binary compatibility with existing installs.
- Release runner upgraded to `macos-15` for Swift 6.0 tools; language mode
  pinned to Swift 5 for CI reproducibility.

### Fixed
- `SessionStore`: replaced `Task.sleep(for:)` with an injected `delay`
  closure to avoid the `swift_task_dealloc` abort reported under concurrent
  load (see commit `fffadbc`).
- `MenuBarIconRenderer` isolated to `@MainActor` for Swift 6 strict
  concurrency compliance.

## [0.1.0] — 2026-04-22

Initial public release.

### Added
- Native macOS menu-bar app that centralizes `PreToolUse` approvals across
  concurrent Claude Code sessions.
- Three-state menu-bar icon (idle / pending / auto-allow) with template image
  that auto-inverts for light/dark.
- Pinnable popover (hand-rolled `NSStatusItem` + `NSPanel`).
- Main window: session sidebar + approval queue with collapsible tool inputs
  and risk-edge coloring (red for destructive, amber for write-capable).
- Temporary trust windows per session (2 / 10 / 30 minutes) and "Allow all"
  (⌘↩) batch action.
- Embedded Hummingbird HTTP + WebSocket server on `127.0.0.1:7788`.
- Native `UserNotifications` for incoming approvals and finished sessions.
- `install-hooks.sh` CLI installer and app-side auto-installer; `settings.json`
  is backed up before modification.
- Sparkle auto-update with EdDSA-signed appcast.
- Homebrew Cask distribution via `heypandax/cc-dashboard` tap.

[Unreleased]: https://github.com/heypandax/cc-dashboard/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/heypandax/cc-dashboard/releases/tag/v0.1.2
[0.1.0]: https://github.com/heypandax/cc-dashboard/releases/tag/v0.1.0
