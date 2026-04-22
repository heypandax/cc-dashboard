# Contributing to cc-dashboard

Thanks for taking the time. This is a small hobby project — contributions are
welcome but I can't promise fast turnaround. Read this first to avoid wasted
effort on either side.

Participation in this project is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md) — please read it before engaging.

## Before opening a PR

1. **Open an issue first** for anything beyond a typo or obvious one-line fix.
   I'd rather discuss approach with you than reject a finished PR.
2. **Keep the scope tight.** One PR = one concern. "While I was in there I
   also refactored X" is how small changes turn into 800-line reviews that
   never merge.

## Local development

Requirements:

- macOS 14+
- Xcode 16 or later (for `actool` / Icon Composer / Swift 6 toolchain)
- `jq` (only if you run `install-hooks.sh` directly)

```bash
# Clone + resolve
git clone git@github.com:heypandax/cc-dashboard.git
cd cc-dashboard
swift package resolve

# Build + run dev bundle
./make-bundle.sh                       # Release + Developer ID (if available)
CC_SIGN_IDENTITY=- ./make-bundle.sh    # Ad-hoc signing (no Developer account needed)
open dist/cc-dashboard.app

# Uninstall Claude Code hooks when done experimenting
./install-hooks.sh --uninstall
```

Firebase (Analytics + Crashlytics) is optional for local dev:

- Without `GoogleService-Info.plist` at the repo root, `FirebaseApp.configure()`
  will refuse to start. Either drop in a plist from your own Firebase project,
  or comment out `Telemetry.configure()` in `App.swift` while iterating.
- If you do set up Firebase, treat `GoogleService-Info.plist` as secret —
  `.gitignore` already excludes it.

## Running tests

```bash
swift test
```

Tests live in `Tests/CCDashboardTests/`. The `SessionStore` actor accepts
injected `now` / `delay` closures so tests don't depend on wall clock.

## Code style

Follow the **[Swift API Design Guidelines][design]** and whatever
surrounding code is already doing.

[design]: https://www.swift.org/documentation/api-design-guidelines/

A few project-specific rules, from repeated review feedback:

- **Comments explain WHY, never WHAT.** Well-named identifiers already say
  what the code does. Keep comments when they record a non-obvious
  constraint, workaround, or past bug ("see commit fffadbc"). Delete
  anything that narrates the change itself.
- **Don't add error handling for scenarios that can't happen.** Trust
  internal contracts. Only validate at system boundaries (hook input, HTTP
  request body, user input). See `riskLevel(for:)` — it's deliberately
  heuristic, not exhaustive.
- **No new design tokens inline.** Colors / fonts / spacing go through the
  `CC` enum in `Sources/CCDashboard/UI/Tokens.swift`.
- **Telemetry events stay typed.** Add cases to `Telemetry.Event` / `Telemetry.Key`
  instead of passing raw strings; never upload command contents or file paths.

## Localization

UI strings live in `Resources/en.lproj/Localizable.strings` (source of truth)
and `Resources/zh-Hans.lproj/Localizable.strings`. When you add a new SwiftUI
`Text(...)` or `Button(...)` with a user-facing label, add both entries.
SwiftUI literal strings are already `LocalizedStringKey` — no code change
needed beyond the `.strings` file.

For runtime-built strings (like `Notifier`'s notification titles), use
`String(localized: "...")` — see `Sources/CCDashboard/UI/Notifier.swift`
for the pattern.

## Commit messages

- Use imperative mood: "Add X" not "Added X".
- Subject line ≤ 72 chars; focus on **why** in the body.
- Don't include `Co-Authored-By` lines for AI-assisted changes unless the
  human author explicitly wants attribution.
- User-visible changes should also land a line in [`CHANGELOG.md`](CHANGELOG.md)
  under `[Unreleased]`. Plumbing that's invisible to users doesn't need one.

## Two namespaces, by design

You'll see two similar-looking identifiers in this repo — they are not typos:

- **`com.heypanda.cc-dashboard`** — Apple reverse-DNS. Bundle identifier,
  LaunchAgent label, UserDefaults domain, `os.Logger` subsystem. Changing this
  would orphan every existing install's state (auto-allow windows, opt-out
  flag, scheduled jobs), so it is pinned for the life of the project.
- **`heypandax`** — GitHub handle. Used for `github.com/heypandax/…` URLs,
  the `heypandax/cc-dashboard` Homebrew tap, and the `heypandax.github.io`
  appcast host.

The two live in different ecosystems and don't need to match. Don't rename
one "to match" the other.

## Reporting bugs

Open an issue with:

- macOS version (`sw_vers`)
- cc-dashboard version (menu bar → Check for Updates or the sidebar footer)
- Exact repro steps
- Relevant `Console.app` log output, filtered by subsystem
  `com.heypanda.cc-dashboard` (see `Sources/CCDashboard/Core/Log.swift`)

Crash reports are automatically captured via Firebase Crashlytics and
symbolicated — often I can see the stack before you file the issue.

## License

Contributions are licensed under the [MIT License](LICENSE), same as the
project. By opening a PR you agree to this.
