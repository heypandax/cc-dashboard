# Security Policy

## Reporting a vulnerability

**Do not open a public GitHub issue** for security problems.

Email: **pandaleecn@gmail.com** with `[cc-dashboard security]` in the subject.

Or use **[GitHub Security Advisories][gha]** — private by default, works well
for coordinated disclosure.

[gha]: https://github.com/heypandax/cc-dashboard/security/advisories/new

Include, ideally:

- Exact version(s) affected (see main window sidebar footer or `Info.plist`)
- macOS version
- Steps to reproduce
- Impact you've observed or can reason about

## Response expectations

This is a hobby project maintained in spare time — no SLA. Realistic
expectations:

- Acknowledge within **7 days**
- Initial assessment within **14 days**
- Patch turnaround depends on severity and my schedule; critical issues
  get prioritized

If a vulnerability is being actively exploited, say so in the subject and
I'll escalate.

## Scope

**In scope:**

- The macOS app itself (everything under `Sources/`)
- The hook wrapper scripts (`hooks/pretool.sh`, `hooks/lifecycle.sh`)
- The embedded HTTP/WebSocket server listening on `127.0.0.1:7788`
- Build scripts (`make-bundle.sh`, `install-hooks.sh`,
  `install-launch-agent.sh`, `scripts/*`) if you find a way to exploit them
  on someone else's machine

**Out of scope** (report upstream):

- Sparkle framework — [sparkle-project/Sparkle][sparkle]
- Hummingbird / HummingbirdWebSocket — [hummingbird-project][hb]
- Firebase iOS SDK — [firebase/firebase-ios-sdk][fb]
- Claude Code itself — [Anthropic][anthropic]

[sparkle]: https://github.com/sparkle-project/Sparkle/security
[hb]: https://github.com/hummingbird-project/hummingbird/security
[fb]: https://github.com/firebase/firebase-ios-sdk/security
[anthropic]: https://www.anthropic.com/vulnerability-disclosure-policy

## What we care about

In rough priority order:

1. **Server-side attack on localhost:7788** — the HTTP server accepts
   POSTs on localhost and auto-allow decisions flow through it. A
   same-user process bypassing approval, or a network-adjacent attacker
   reaching 127.0.0.1 via a browser SSRF etc., would be serious.
2. **Code injection via hook input** — the PreToolUse hook receives JSON
   from Claude CLI and passes it into the app. Anything that lets that
   JSON exfiltrate user content or execute code.
3. **Privilege escalation via LaunchAgent install** — the
   `install-launch-agent.sh` script writes a `~/Library/LaunchAgents/`
   plist. Any way a third party gets a malicious plist written through
   this path.
4. **Telemetry privacy regression** — we commit to never uploading
   command strings, file paths, cwd, tool inputs, or session IDs. A
   regression that leaks any of this is treated as a vulnerability, not
   a bug.
5. **Sparkle / update channel compromise** — we ship notarized DMGs
   signed with Developer ID and verified via Sparkle's EdDSA signature.
   Any way to get a user to install a malicious update is serious.

## Non-issues

- "The hook intercepts Claude Code tool calls" — that's the intended
  design; users opt in by installing the hook.
- "The app listens on 127.0.0.1:7788" — localhost-only, same user. The
  port is documented.
- "`CC_TEST_CRASH=1` crashes the app in debug builds" — it's a DEBUG-only
  onboarding test for Crashlytics, stripped from Release. Can't be
  triggered on a shipped DMG.

## Disclosure

After a fix ships, we publish an advisory on GitHub with credit to the
reporter (unless they prefer anonymity). Critical issues get a
backported fix + Sparkle update within days of the patch landing.
