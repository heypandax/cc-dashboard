# cc-dashboard · 自媒体头像 Prompt (GPT Image 2)

打遍 X / 小红书 / 即刻 / 公众号 / GitHub 的一套作者头像。
风格：**扁平矢量插画**（Pablo Stanley / Koto Studio / Linear editorial）+ 品牌色融合。
前提：ChatGPT Plus 及以上（Thinking 模式），一张本人的清晰正面照。

## 调用参数

| 项 | 值 |
| --- | --- |
| Model | `gpt-image-2` |
| Endpoint | `/v1/images/edits`（因为要传参考照） |
| Size | `1024x1024` |
| Quality | `high` |
| n | `4`（一次出 4 张挑一张） |
| 模式 | Thinking（likeness 保真 + palette 校验都需要） |

## 使用步骤

1. 在 ChatGPT 打开 Thinking 模式。
2. 先贴一次下面的「品牌锚点」。
3. 上传参考照（光线干净、面部清晰、肩部以上的正面或三分之二侧脸）。
4. 贴「主 Prompt」，`n=4` 挑一张。
5. 挑出最满意的那张后，**把那张生成图作为下一轮参考**（不要再用原始自拍），跑「延伸 Prompt」出 banner / 公众号封面 / GitHub 版，形成一套视觉家族。

## 品牌锚点

- 主色：deep indigo `#1B2E4A → #2E4A6B` 渐变
- 强调：mint `#4ADE80`（品牌签名点）
- 服装：charcoal dark-slate `#2B3442`（和背景区分但不抢戏）
- 皮肤平铺色：warm flat `#EAD3B8`
- 调性对标：Pablo Stanley / Koto Studio / Linear editorial illustration
- 避开：Anthropic orange、neon / hologram / cyberpunk、发光电路、3D 写实、水彩素描感、anime、动画过度美型

---

## 主 Prompt（头像本体 · 扁平矢量）

```
Generate a minimalist flat vector portrait avatar based on the uploaded reference photo. This is an illustration, NOT a realistic render — treat the reference as identity guidance, not as a target to photoreplicate.

Framing: head and shoulders, three-quarter angle facing slightly left (same orientation as the reference), direct confident eye contact with the viewer. Subject's head centered in the upper-middle of the frame.

Subject characteristics to reference:
- Clean-shaven East Asian male, late 20s / early 30s
- Short black hair with naturally tousled top, matching the hairline shape in reference
- Thin round metal-frame glasses, matching the frame shape and thinness in the reference
- Warm, faintly amused closed-mouth smile, calm eyes — same mood as the reference, do not exaggerate

Capture likeness through exactly four anchors: exact hairline shape, exact round glasses frame geometry, jaw shape, and the faint closed-mouth smile. These four anchors make the avatar read as this specific person at a glance. Other facial features may be simplified.

Clothing: clean charcoal dark-slate crew-neck sweater #2B3442, flat color, no texture, no logo, no print, simple ribbed neckline indicated by a single line.

Rendering style: clean flat vector illustration.
- 2–3 flat color planes per form, no gradients, no photorealistic shading.
- Face has ONE flat shadow plane on the shaded side only. No nose shading, no under-eye shadows, no pores, no cheek highlights.
- Hair is a single solid black silhouette shape with one small flat highlight plane at the top.
- Skin rendered as a single warm flat tone #EAD3B8 — not a texture, not multiple tones.
- Clean monoline contours (1.5pt equivalent at 1024px, off-white #E8F0FC) trace the jaw, glasses frame, hair silhouette edge, and collar.
- Reference aesthetic: Pablo Stanley / Koto Studio / Linear editorial illustrations. NOT anime, NOT 3D, NOT watercolor, NOT pencil sketch, NOT semi-realistic.

Background: solid deep indigo radial gradient #1B2E4A → #2E4A6B, soft centered vignette behind the subject. No shelves, no vases, no plants, no props, no environment. In the upper-right of the frame, a single small mint-green dot #4ADE80 (≈8px at 1024x1024) as a quiet brand signature — unlabeled, no text near it.

Palette discipline: all elements strictly within #1B2E4A, #2E4A6B, #2B3442, #EAD3B8, #E8F0FC, #4ADE80, plus natural black hair. No neon, no hologram, no gradient shading on the subject, no glowing circuits, no warm earth tones beyond the skin tone.

The avatar must remain recognizable as the same specific person at 40x40px — glasses shape clearly visible, hair silhouette distinct, jaw shape true.

No text, no logos, no emoji, no 3D depth, no environment props. 1024x1024, 1:1.
```

---

## 变体：更温暖一点的米色上衣（更"生活感"）

如果觉得 charcoal sweater 冷硬，想保留你照片里的米色 tee 气质。把主 prompt 的 **Clothing** 段替换为：

```
Clothing: warm beige flat-fill crew-neck tee #D9C5A8, flat color, no texture, no logo, no print, simple neckline indicated by a single line.
```

并把 **Palette discipline** 里的 `#2B3442` 替换为 `#D9C5A8`。

---

## 延伸 Prompt（一套视觉家族）

挑出满意的主头像之后，**把那张生成图作为下一轮的参考**上传。这样所有延伸版都继承扁平矢量风格 + 同 palette。

### X（Twitter）header · 3:1

```
Same subject, same flat vector illustration style, same palette as the attached avatar. Reframe to a 3:1 horizontal banner. Subject positioned in the right third of the frame, left two-thirds is clean deep indigo #1B2E4A → #2E4A6B negative space suitable for text overlay. Maintain exact face likeness, clothing, glasses, hairline from attached. Single mint-green dot #4ADE80 small in the upper-right corner.
```

建议调用：`size="1792x1024"`, `quality="high"`, `n=1`（后期裁到 3:1 / 1500x500）。

### 公众号 / 小红书封面 · 半身版

```
Same subject, same flat vector illustration style, same palette as the attached avatar. Extend the framing to waist-up. Subject calmly holds a closed matte-dark laptop #2B3442 in both hands at chest level, looking slightly off-camera in a thoughtful pose. Same deep indigo #1B2E4A → #2E4A6B background, no environment, no props. Same clothing, glasses, hairline as attached. Preserve exact likeness. 1024x1024, 1:1.
```

### GitHub / Homebrew / Product Hunt maker · 纯背景版

```
Same subject, same flat vector illustration style, same clothing and glasses as the attached avatar. Replace the gradient background with a flat solid #1B2E4A — no gradient, no vignette, no signature dot. Tighter head-and-shoulders crop. Preserve exact likeness. 1024x1024, 1:1.
```

---

## 注意事项

- **无透明背景**：Image 2 不支持透明 PNG。需要的话生成后用 Photoshop / Preview / Figma 抠。
- **40×40 辨识**：每次出图后立刻缩到 40×40 看一眼，眼镜、发型轮廓、脸型必须还能辨。
- **面部走样**：如果某张 variation 脸变了（眼间距、眉型、下巴走形），直接丢，不要留着凑数。`n=4` 通常至少一张过关。
- **不要偏向 3D**：如果生成结果出现 subsurface scattering 皮肤 / 立体阴影，在 prompt 末尾强化一次：`Strictly 2D flat vector. No 3D, no photorealism, no subsurface scattering, no gradient on skin or hair. Any 3D rendering is a failure.`
- **palette 漂移**：如果出现米色 / 灰绿 / 暖褐等非 palette 色，末尾加强：`Strict palette lock: only #1B2E4A, #2E4A6B, #2B3442, #EAD3B8, #E8F0FC, #4ADE80, plus natural black hair. Any other hue is a failure.`
- **一致性是资产**：X / 小红书 / 即刻 / GitHub / 公众号 / Product Hunt 用同一张主头像，延伸版只在需要不同比例时用。不要频繁换。
