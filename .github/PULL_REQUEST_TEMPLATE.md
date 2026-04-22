<!--
Please read CONTRIBUTING.md first. For anything beyond a typo or obvious
one-line fix, open an issue before starting work so we can align on approach.
-->

## Summary

<!-- One or two sentences: what does this PR do, and why? Focus on "why". -->

## Linked issue

<!-- e.g. Fixes #123 / Closes #123 / Related to #123 -->

## How was this tested?

<!--
- [ ] `swift test` passes locally
- [ ] Built a local bundle via `./make-bundle.sh` and ran it
- [ ] For UI changes: tested in both light and dark mode
- [ ] For localization changes: updated both `en.lproj` and `zh-Hans.lproj`
-->

## Checklist

- [ ] Scope stays tight (one PR = one concern)
- [ ] No new design tokens inline — colors / fonts / spacing go through `CC` in `Tokens.swift`
- [ ] No new raw-string event names — use `Telemetry.Event` / `Telemetry.Key`
- [ ] Telemetry: I did not add any event that uploads user content (command text, file paths, cwd, session IDs)
- [ ] Comments explain WHY (non-obvious constraint, workaround, past bug) — not WHAT
