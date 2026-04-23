# cc-dashboard · Social Media Image Prompts (GPT Image 2)

一套针对 **ChatGPT Images 2.0 / `gpt-image-2`**（2026-04-21 发布）优化的提示词，覆盖 Twitter/X · 小红书 · Product Hunt · 公众号 · GitHub social preview 等场景。

## GPT Image 2 调用速查

| 项 | 值 |
| --- | --- |
| Model | `gpt-image-2` |
| Endpoints | `/v1/images/generations` · `/v1/images/edits` |
| 官方尺寸 | `1024x1024` · `1792x1024` · `1024x1792`（2K 档延伸至长边 2560） |
| 支持比例 | 1:1 · 3:2 · 2:3 · 16:9 · 9:16 · 3:1 · 1:3 |
| `quality` | `low`（≈$0.006）/ `medium`（≈$0.053）/ `high`（≈$0.21） |
| `n` | 1–8，多图一致性（Thinking 模式下效果最好） |
| 模式 | Instant（所有用户）· Thinking（Plus/Pro/Business/Enterprise，启用 reasoning / 联网 / 批次一致 / 自检） |
| 透明背景 | 不支持 |
| 文本渲染 | 中文 / 英文 / CJK / Hindi / Bengali 都可直接写，**不必再加英文 fallback** |

## 使用方式

1. 在 ChatGPT 里打开 Thinking 模式（如果你是 Plus 及以上），其它场景 Instant 即可。
2. 每次先贴一次「品牌锚点」，再贴对应场景的 prompt。
3. 轮播图（第 6 条）在 Thinking 模式下走一次 `n=3`，一组出。

## Thinking 模式前缀（可选）

Plus/Pro 用户在 Thinking 模式下，把这段放在每条 prompt 最前可以让 reasoning 更有用：

```
Before rendering: plan the composition, lock the palette to the exact hex list provided, verify UI elements are pixel-accurate to SwiftUI conventions, and verify no emoji / no out-of-palette color appears. Then render the final image.
```

## 品牌锚点（每次固定贴一次）

- 主色：deep indigo `#1B2E4A → #2E4A6B` 渐变
- 强调：mint `#4ADE80`（Allow / 成功）
- 风险：red `#F87171` / amber `#F59E0B`
- 调性对标：Raycast · Linear · Things 3 · Arc · Warp 的 landing 级精致感
- 避开：Anthropic orange、终端 skeuomorphism（CRT 辉光、扫描线）、glossy AI 视觉、emoji、营销感标语、脑子 / 神经元 / 发光电路
- Palette lock（严格）：only `#1B2E4A`, `#2E4A6B`, `#0F1A2E`, `#E8F0FC`, `#4ADE80`, `#F87171`, `#F59E0B` — no other hues

---

## 1. Hero 主视觉 · 16:9

**用途**：Twitter 卡片 / Product Hunt cover / 公众号封面 / GitHub social preview / 官网 OG 图。
**建议调用**：`size="1792x1024"`, `quality="high"`, `n=1`, Thinking 模式。

```
A polished marketing hero image for a macOS menu bar developer tool called "cc-dashboard".
Slightly isometric overhead perspective of a dark, minimal developer workspace on an M-series MacBook Pro.
At the top of the screen the macOS menu bar is crisp, with a small BLACK MONOCHROME icon: a rounded rectangle outline containing 3 horizontal lines, with a tiny filled dot at the top-right corner (pending approval).
Directly beneath the icon, a floating macOS popover is open — Liquid Glass style, 16pt rounded corners, subtle blur, 1px light stroke. The popover is a vertical stack of 3–4 "approval cards": each card has a small header reading "Bash" or "Edit", a one-line monospace command snippet (render the text pixel-sharp, correctly spelled), and two buttons — a mint-green "Allow" pill and a muted red "Deny" pill. ONE card has a red left edge indicating a destructive command.
Around the popover, softly defocused in the background, 2–3 terminal windows stream Claude Code output.
Palette locked to: #1B2E4A → #2E4A6B gradient background, #E8F0FC card surfaces, #4ADE80 Allow accent, #F59E0B amber warning dot, #F87171 red risk edge. Cool ambient light from upper-left.
Aesthetic reference: Raycast / Linear / Things 3 / Arc browser marketing shots — calm, precise, engineering-grade.
No text beyond the native UI labels. No emoji. No Anthropic orange. No CRT scanlines. Photoreal, 16:9, 1792x1024.
```

**搭配文案**：
- EN: *One menu bar app to approve every Claude Code tool call — across every session you're running.*
- 中：跑几个 Claude Code 就要在几个终端之间追着 y/n。cc-dashboard 把审批收到菜单栏一个图标 —— 一眼看清，一键批完。

---

## 2. 产品概念图 · 1:1

**用途**：Twitter 单图 / 小红书首图 / 朋友圈 / Discord。
**建议调用**：`size="1024x1024"`, `quality="high"`, `n=1`。

```
A minimal abstract isometric illustration for a developer tool.
Centered: a clean squircle app icon in deep indigo gradient (#1B2E4A → #2E4A6B) containing a stylized "console card" with three horizontal off-white lines; the topmost line ends in a small mint-green check glyph (#4ADE80). Subtle top-left glass highlight, Apple HIG proportions.
Radiating from the icon: five thin semi-transparent line connections to five small floating "terminal window" glyphs arranged in a halo (top, upper-right, right, lower-right, lower-left). Each small terminal is a simplified rounded rectangle with three traffic-light dots and a few tiny code lines. Two of them carry a muted red indicator dot (risky approval waiting). The five terminals visually funnel into the central icon — convey orchestration and convergence.
Background: flat deep indigo #141C2B with a soft vignette.
Palette locked: only #1B2E4A, #2E4A6B, #141C2B, #E8F0FC, #4ADE80, #F87171.
Aesthetic: Linear / Raycast marketing — geometric, calm, high-end engineering tool.
No text, no logos, no emoji, no Anthropic orange, no AI cliches (no brains, no neurons, no glowing circuits).
1:1 square, vector-crisp, 1024x1024.
```

---

## 3. 图标特写 · 1:1

**用途**：Product Hunt icon 位 / Twitter 头像 / 文章小图 / Homebrew 展示。
**建议调用**：`size="1024x1024"`, `quality="high"`, `n=1`。

```
A hero product shot of a single macOS app icon for "cc-dashboard".
Apple-HIG squircle canvas. Background gradient: #1B2E4A at the bottom to #2E4A6B at the top, with a subtle glass-like highlight at the top-left.
Centered: a rounded rectangular "console card" occupying ~55% of the canvas width. Card surface is off-white #E8F0FC, slightly frosted. Inside the card, three evenly spaced horizontal lines (monoline, 1.5pt stroke equivalent at 1024px). The topmost line terminates in a small mint-green checkmark glyph (#4ADE80) — an approval just granted.
No text, no wordmark, no terminal prompt character.
Place the icon floating on a soft neutral charcoal gradient backdrop with a gentle contact shadow beneath — product-photography style.
Reference: Things 3 / Linear / Raycast icons. Calm, precise, engineering-tool quality. Not glossy, not playful, not AI-generic.
1024x1024, 1:1.
```

---

## 4. 痛点对比图 · 16:9

**用途**：小红书首图 / 公众号开头 / Twitter thread 第一张。
**建议调用**：`size="1792x1024"`, `quality="high"`, Thinking 模式。

```
A split-screen "before vs after" editorial illustration for a developer tool, cinematic overhead perspective. No text, no labels — composition carries the contrast.
LEFT HALF — "before": a cluttered dark macOS desktop with 6–8 overlapping Terminal windows, each paused mid-command waiting for a y/n prompt. Small warning indicators hover above the terminals. Cold desaturated blue-gray palette, visually busy, fragmented.
RIGHT HALF — "after": the same desktop, almost empty. Only the macOS menu bar at top, a single small monochrome icon (rounded rect + three lines + tiny dot) subtly highlighted, and one clean floating popover showing a stacked list of approval cards with mint-green Allow buttons. Warm-leaning cool-indigo palette. Breathing room.
A thin vertical seam separates the two halves. Palette locked: #1B2E4A → #2E4A6B, #E8F0FC, #4ADE80, #F87171 (used only on the "before" side), #F59E0B.
Aesthetic: Apple keynote editorial rendering. No emoji, no arrows, no AI cliches. Photoreal UI, clean geometry. 16:9, 1792x1024.
```

---

## 5. 竖屏氛围图 · 9:16

**用途**：小红书主图 / Instagram Story / 手机分享。
**建议调用**：`size="1024x1792"`, `quality="high"`。

```
Vertical 9:16 cinematic photo-illustration of a late-night indie developer workspace on a walnut wood desk.
Hero: a MacBook Pro (matte dark) open at a three-quarters angle. On screen: dark macOS environment, menu bar crisp at top. ONE small icon in the menu bar is gently highlighted — rounded rectangle with three horizontal lines and a tiny mint-green dot. Below the icon, a rounded popover is open, floating over softly blurred terminal windows, showing 3 stacked approval cards with clearly legible mint "Allow" buttons.
Environment: warm tungsten desk lamp from top-right, a ceramic coffee mug (unbranded) with subtle steam, a small potted plant, rain softly streaking an unseen window and reflecting in the laptop's lower edge. Mostly cool indigo-to-navy, the screen and desk lamp the only warm accents. Shallow depth of field; keyboard and front of desk out of focus.
Mood: focused, calm, late-night-shipping. Taste: Things 3 launch imagery, Arc browser marketing, Panic Inc. product shots.
No text overlays, no brand logos besides a dim Apple logo. No emoji. Photoreal, 9:16, 1024x1792.
```

---

## 6. 功能卖点轮播 × 3（单次 `n=3`，Thinking 模式）

**用途**：小红书多图帖 / 公众号内嵌 / Twitter thread 配图。
**建议调用**：`size="1024x1024"`, `quality="medium"`, `n=3`, Thinking 模式（保证 3 张同底同光同 palette）。

```
Generate a 3-image carousel as a single coherent set. All three images share IDENTICAL palette, lighting, camera, and background — they must read as a designed series.

Shared art direction (applies to all 3):
- Canvas: #0F1A2E base with a subtle #1B2E4A → #2E4A6B top-to-bottom gradient.
- Centered composition, one UI element per card, rendered crisply like a design-tool mockup.
- Palette locked: only #0F1A2E, #1B2E4A, #2E4A6B, #E8F0FC, #4ADE80, #F59E0B, #F87171.
- Aesthetic: Raycast / Linear / Things 3 editorial. No labels, no captions, no emoji, no Anthropic orange.
- Each image 1024x1024, 1:1.

IMAGE 1 — "Three-state menu bar icon":
Three black monochrome icons in a row, each inside a faint rounded tile. Icon shape: rounded rectangle outline with three horizontal lines inside.
- Left: icon alone (idle).
- Middle: icon + small filled solid dot at top-right (pending).
- Right: icon + small hollow ring at top-right (auto-allow active).
Soft spotlight on the middle "pending" variant.

IMAGE 2 — "Temporary trust window":
One approval card floating centered. Header reads "Bash", a truncated monospace command snippet beneath (sharp, correctly spelled). Below the main Allow button a submenu is expanded showing three stacked options: "Allow for 2 min", "Allow for 10 min", "Allow for 30 min". In a corner, a thin mint-green progress ring around a small 10:00 countdown anchors the concept.

IMAGE 3 — "Risk hints":
Three stacked approval cards. Each card has a colored LEFT EDGE only:
- Top: red edge, monospace line shows a partial "rm -rf …" destructive command.
- Middle: amber edge, shows an Edit tool call with a file path stub.
- Bottom: no edge, shows a safe "git status" read-only command.
The red / amber / neutral rhythm tells the risk story without any words.

Verify before output: identical background gradient, identical lighting angle, identical card geometry across all 3 images. Return as a batch of 3.
```

---

## 中文 UI 变体（小红书 / 公众号）

GPT Image 2 渲染中文稳定，直接在对应 prompt 末尾追加：

```
Render all UI labels in Simplified Chinese with proper kerning and baseline alignment:
- "允许" instead of "Allow"
- "拒绝" instead of "Deny"
- "全部允许" instead of "Allow all"
- "信任 2 分钟 / 10 分钟 / 30 分钟" for the auto-allow submenu
Use SF Pro SC or equivalent system-native Chinese typography; do not mix fonts.
```

---

## 通用调校

| 症状 | 追加到 prompt 末尾 |
| --- | --- |
| 边缘糊 / 像插画 | `Ultra-sharp edges, design-tool grade rendering, no painterly texture.` |
| UI 不像真 macOS app | `Render UI elements as if screenshotted from a real SwiftUI macOS 14+ app — pixel-accurate to Apple HIG.` |
| 一组图风格不统一 | 改走 `n=3` 单次多图（见第 6 条）；或者把第 1 张作为 reference image 上传再生后续。 |
| 配色漂移 | `Strict palette lock: only #1B2E4A, #2E4A6B, #E8F0FC, #4ADE80, #F87171, #F59E0B. Any other hue is a failure.` |
| 文本拼错 | `All rendered text must be spelled exactly as provided; treat text as a hard constraint, not a stylistic suggestion.` |
| 想留 logo / 商用 | Image 2 logo 稳定性仍不足，商用前用 Figma / Sketch 人工叠真 logo。 |

## 已知限制（心里有数）

- **无透明背景**：要透明 PNG 的场景（比如叠到其它设计稿）需要生成后用 Photoshop / Affinity 抠。
- **知识截止 2025-12**：不要提 2026 之后的潮流 / 产品 / 人物，会生成"看起来对但事实错"的视觉。
- **品牌 logo**：不要指望它准确复刻 Apple / OpenAI / 任何 logo，要精确 logo 另外叠图。
- **Thinking 模式 +15–30s 延迟**：批处理或想快速迭代时改 Instant。
