# cc-dashboard · Icon Set Design Brief

## Product

cc-dashboard is a native macOS menu bar app that orchestrates concurrent
Claude Code terminal sessions. Developers run 5–10 Claude Code sessions
in parallel; each session interrupts with permission approvals (Bash /
Edit / Write). cc-dashboard centralizes those approvals into one menu
bar UI and adds "temporary trust" (auto-allow for N minutes).

Keywords the design should convey: orchestration, trust, calm,
developer-native. Avoid: generic terminal icons, over-glossy AI visuals,
Anthropic's signature orange (this is an independent tool).

## Visual language

Abstract geometry, not literal terminal.

- Primary motif: a rounded "console card" containing three horizontal
  session lines; the topmost line terminates in a small mint-green
  checkmark (an approval just granted).
- Palette:
  - Background gradient: deep indigo #1B2E4A (bottom) → #2E4A6B (top)
  - Card / lines: off-white #E8F0FC
  - Approval accent: mint #4ADE80
- Mood: calm, precise, engineering-tool quality (think Linear, Raycast,
  Things 3 — not Figma, not OpenAI).

## Deliverable 1 — App Icon (1024 × 1024)

- macOS squircle canvas, Apple HIG proportions.
- Centered console card occupies ~55% of canvas width, subtle
  glass-like top-left highlight, no hard border.
- Inside the card: three evenly spaced horizontal lines, 1.5pt stroke
  equivalent at 1024px. Top line ends with a mint checkmark glyph.
- No text, no wordmark, no terminal prompt character.

Please also produce two Sequoia-style variants:

- Dark: background deepens to #0F1A2E, card brightens slightly.
- Tinted (monochrome): white card outline + three lines + checkmark
  only, on flat dark gray. No gradient.

## Deliverable 2 — Menu Bar Icon (template image, 16pt × 16pt)

**HARD CONSTRAINT**: template image. Pure black foreground on transparent
background. macOS auto-inverts for dark mode. **DO NOT add color** — any
color will be stripped by the OS.

Base form mirrors the app icon: a simple rounded rectangle outline
containing three horizontal lines. 1.5pt stroke at 16pt. Must stay
legible at 16×16 and crisp at 32×32 (@2x).

Produce three states that differ **ONLY in shape** (not color):

1. **idle** — base form, nothing else
2. **pending** — base form + filled solid dot at top-right corner
   (≈4pt diameter, touching but outside the rectangle)
3. **auto-allow** — base form + hollow ring at top-right corner
   (≈4pt outer diameter, 1pt stroke, same position)

Rationale: filled = "action needed", hollow = "status indicator". This
keeps a calm menu bar while remaining glanceable.

## Output format

- App icon: 1024×1024 PNG (light, dark, tinted — three files).
- Menu bar icons: SVG for all three states, plus 16×16 and 32×32 PNG
  exports. Black on transparent.
- Optional: Figma frame or source file for follow-up edits.

## Non-goals

- No dock bounce animation, no loading states — static only.
- No Anthropic logo or wordmark reference.
- No skeuomorphic terminal (no scanlines, no CRT glow, no cursor).
