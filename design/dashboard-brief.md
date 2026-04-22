# cc-dashboard · Main Window Design Brief

## Product context (recap from icon brief)

cc-dashboard is a native macOS menu-bar + main-window app that orchestrates
concurrent Claude Code terminal sessions. Developers run 5–10 sessions in
parallel; each session frequently pauses to ask permission for Bash / Edit /
Write / MultiEdit / WebFetch. The dashboard centralizes those approvals.

Icon set already shipped (V2: deep-indigo squircle, stacked console cards,
mint check). The main window should belong to the same family.

## What the main window does today

macOS `NavigationSplitView`, two panes:

### Sidebar (260–400pt)
Header "Sessions · N" (active count). Each row shows one session:
- colored status dot (running / waitingApproval / idle / done / error)
- monospace session id prefix, 8 chars
- optional **trust badge** (mint pill with live countdown, e.g. `auto 9:42`)
  when an auto-allow window is active — click to cancel
- relative time (`5m ago`)
- cwd path (single line, truncated head)
- `tool: Bash` caption

### Detail pane
Either empty state (centered icon + "No pending approvals") or a list of
approval cards:
- tool name headline + session id prefix
- cwd (truncated head)
- **tool_input block**: key:value lines in monospace, collapsible past 3
  lines with a "Show more" toggle
- buttons: primary **Allow** (green), menu **Allow for… 2/10/30 min**
  (opens a tiny submenu), **Deny** (red tint)
- relative time
- toolbar **Allow all** (green checkmark, top-right, only when pending > 0)

## Design goals

1. **Glanceable triage** — within half a second: do I need to do anything,
   or can I get back to coding.
2. **Approval cards are the protagonist**. Sessions list is supporting UI.
3. **Safety cues by risk** — `rm -rf`, `curl | sh`, writes outside project
   cwd should *feel* different from `ls` or `git status`. Not alarmist,
   just legible. Think subtle edge color, not red flashing banner.
4. **"Allow all" visible, not default**. It's a power-user shortcut — give
   it the right weight so it's not the first thing a hand lands on.
5. **Dark mode equally at home**. This app runs alongside terminals and
   editors; it should blend, not compete.

## Screens to design

Label each artboard clearly.

### 1 — Empty state
Default resting state. Sidebar: 0–3 sessions (running or idle). Detail:
calm, not blank. Scaled-up version of the app-icon motif + subtext like
*"Nothing to review. Sessions will show up here when they need you."*

Optional: show a sparse activity summary (e.g. "12 approvals resolved in
the last hour, 2 auto-allow windows active"). Your call — recommend
whichever makes the page feel less dead without inventing fake data.

### 2 — One pending approval
Single approval card, full attention. `tool_input` prominent (it's what
the user must read). Allow button obvious; Deny equally reachable.
Show all button variants including the `Allow for 10 min` submenu state.

### 3 — Multiple pending approvals (4–8 cards)
The hard case. Multiple sessions waiting. Cards stack vertically and
scannable. "Allow all" visible in the toolbar. If grouping by session
helps scanability, do it. If not, keep flat. Recommend.

### 4 — Active auto-allow (trust) session in sidebar
Show what the sidebar looks like when one session has a 10-minute trust
window active. The countdown badge must be unmistakable — the user granted
automation, they need to feel it's happening.

### 5 — Dark mode
Screens 1 and 3 in macOS dark materials. Translucent sidebar, solid
detail area. Use macOS semantic materials, not flat dark gray.

## Design system

### Palette (continuous with app icon)
- Primary / brand: deep indigo `#1B2E4A → #2E4A6B`
- Surfaces: macOS system materials (sidebar translucent, detail solid)
- Accent positive (Allow, trust active): mint `#4ADE80`
- Accent attention (approval waiting > 60s): warm amber — subtle
- Accent danger (Deny, destructive bash): red
- Neutrals: macOS semantic `primary / secondary / tertiary` label colors

### Typography
- UI: SF Pro
- Session IDs, tool_input, cwd: SF Mono

### Density
Comfortable, not sparse. A MacBook-sized window (1200×800) should
comfortably show ~6 approval cards at once. Window min size 720×440.

## Output format

- **Web prototype** — primary deliverable. HTML + CSS + optional React
  components so I can reverse-engineer the structure into SwiftUI.
- Artboards at both **720×440** (min size) and **1200×800** (comfortable).
- Multiple directions welcome: 2–3 layout variants for the split-view
  relationship (fixed sidebar vs. collapsible vs. tabs vs. single-column).

## Non-goals

- No settings panel — the app has no settings yet.
- No login / onboarding — local-only tool, no accounts.
- No charts, analytics, timeline visualizations.
- No full session detail / transcript viewer — that's future work, don't
  design it.
- No menu-bar popover — I'll derive that from the main-window design.
