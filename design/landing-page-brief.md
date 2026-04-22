# CC Dashboard — Landing Page Prompt (for claude.ai/design)

把下面整段粘到 [claude.ai/design](https://claude.ai/design)。生成完把 `index.html` 存到 `docs/index.html`,push 到 main 即自动 Pages serve。

---

为 macOS 菜单栏 app "CC Dashboard" 设计一个 GitHub Pages landing page。单 HTML 文件 + Tailwind CDN,无 JS 框架依赖,响应式,深色优先。

## 产品定位(一句话)
macOS 菜单栏原生应用,集中管理并发的 Claude Code 会话 —— 一次装,跑 N 个终端里的 Claude Code 都在一个地方点 Allow/Deny,不用在多个终端之间切换追着看 y/n 提示。

## 受众
跑 2+ Claude Code 会话的开发者。Terminal + CLI 文化,都装过 Homebrew,看到 .dmg 不怕。

## 视觉 vibe
- 开发者工具精致感:对标 Raycast / Linear / Arc / Warp 的 landing
- macOS 原生调性,Liquid Glass(macOS 26)的圆角 + 玻璃质感
- 深色默认(开发者偏好),`prefers-color-scheme: light` 切浅色
- 信息密度高,不浪费滚动。不要 parallax / loading spinner / 花哨过渡
- 字体:system stack(`-apple-system, 'SF Pro Text'...`),不拉 webfont
- tone 偏工程师同事之间说明书,不要 emoji、不要感叹号、不要 marketing 词汇(revolutionary / game-changing 之类)

## 品牌色(取自 app 内真实 token)
- 主色 indigo 渐变:顶 `#7C7AE5` → 底 `#5653D9`
- Allow / 成功 mint:`#6EE7B7` / 深 `#10B981`
- Deny / 风险 red:`#F87171`
- Pending / 警告 amber:`#F59E0B`
- 菜单栏 icon 是 template 风格纯剪影:圆角方框 + 内部 3 条横线,右上角可选状态点(实心=待审批 / 空心环=临时信任生效)

## 信息架构(从上到下)

### 1. Hero
- 标题:**CC Dashboard**
- 副标:*One menu bar app to approve every Claude Code tool call — across every session you're running.*
- 主 CTA(粘贴 + 可一键复制):
  `brew install --cask heypandax/cc-dashboard/cc-dashboard`
- 次 CTA:Download DMG(链到 https://github.com/heypandax/cc-dashboard/releases/latest)
- 右侧 hero 图位:放 app 主窗口截图(占位用灰底圆角,标注 `docs/assets/hero.png`)
- 小字:macOS 14+ · Developer ID signed + Apple notarized · Open source

### 2. 核心功能(4-6 个 card,每个一句话 + 极简 inline SVG 图标)
1. **Pending approvals at a glance** — 菜单栏图标三态:idle / 待审批 / auto-allow 生效,一眼知道要不要管。
2. **Batch + granular** — 单个 Allow/Deny、Allow for 2/10/30 min 临时信任、⌘↩ 一把 Allow all。
3. **Risk hints built in** — `rm -rf` / `sudo` / `curl | sh` / `/etc /usr /System` 标红;Edit / Write / MultiEdit / WebFetch 标琥珀。
4. **Pin to stay open** — 默认弹出点外自动关;点图钉钉住后切 App / Space / 全屏都不关,一边审一边干活。
5. **Native & local-only** — 内嵌 HTTP + WebSocket server(127.0.0.1:7788),无 Python / Node 依赖,走 Claude Code 官方 `PreToolUse` hook。
6. **Auto-update via Sparkle** — EdDSA 签名的增量更新。

### 3. How it works(横向 5 步流程图)
Claude Code CLI → PreToolUse hook → 127.0.0.1:7788 → CC Dashboard popover → Allow/Deny 回传 → CLI 继续

强调:**不运行或卡死时自动 fallback 到 Claude 原生 TUI 弹窗,永不阻断 CLI**。

### 4. Install(三栏并列或 tab)
- **Homebrew**(推荐):
  ```
  brew tap heypandax/cc-dashboard
  brew install --cask cc-dashboard
  ```
- **DMG**:Download 按钮 → Latest Release
- **Source**:`git clone … && ./make-bundle.sh`(链到 repo)

### 5. Screenshots(2-3 张占位 card,灰底 + 标注)
- 菜单栏 popover(待审批 + Allow all)
- 主窗口(左 session 列表 / 右审批队列)
- 系统通知弹窗

### 6. Keyboard shortcuts(紧凑 table,mono font)
| 快捷键 | 作用 |
| --- | --- |
| ⌘↩ | Allow all pending |
| ⌘1 / ⌘2 / ⌘3 | Allow for 2 / 10 / 30 min |
| ⌘Q | Quit |

### 7. FAQ(折叠 4-6 条)
- 为什么不上架 Mac App Store?(沙盒与 hook 架构冲突;走 Developer ID + 公证路线)
- 会改我 `~/.claude/settings.json` 吗?(会,追加 5 条 hook,原文件自动备份)
- App 不运行时 Claude Code 能用吗?(能,hook 健康检查 2s 失败自动 fallback 原生 TUI)
- 开源?(MIT,GitHub)
- 收集数据吗?(Firebase 匿名计数 + Crashlytics,**不含**命令内容 / 文件路径 / cwd;一条命令关闭 `defaults write com.heypanda.cc-dashboard analyticsEnabled 0`)

### 8. Footer
- GitHub: `github.com/heypandax/cc-dashboard`
- Issues / Discussions
- License: MIT
- © 2026 heypandax · Built with Swift 6 · Sparkle · Hummingbird

## 技术要求
- 单 `index.html`(要塞进 `docs/` 做 GitHub Pages)
- Tailwind via CDN
- 所有 icon inline SVG(Heroicons outline 风格)
- Copy-to-clipboard 用最小 inline script(`navigator.clipboard.writeText`),没别的 JS
- 无外部字体,无追踪代码
- Lighthouse 目标:Performance / Accessibility / Best Practices / SEO 都 95+
