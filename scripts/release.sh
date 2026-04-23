#!/bin/bash
# cc-dashboard 发版入口。单命令跑完:bump 版本 → 转 CHANGELOG → notarize build →
# 写 appcast + cask → commit + tag + push → GitHub Release + DMG 上传 → 同步 tap 仓 → 验证 Pages。
#
# 用法:
#   ./scripts/release.sh                         # 自动 bump patch (0.1.2 → 0.1.3)
#   ./scripts/release.sh 0.2.0                   # 手动指定(minor / major 必须手动)
#   ./scripts/release.sh 0.1.3 --dry-run         # 跑到 Step 6(本地 tag),不 push / 不建 Release
#   ./scripts/release.sh --skip-notarize         # 跳 notarize + 自动 bump(仅调试脚本,不产可分发 DMG)
#
# CHANGELOG 约定:
#   开发期间把条目加到 `## [Unreleased]` 下。发版时本脚本自动把 [Unreleased] 标题后面
#   插入新的 `## [X.Y.Z] — YYYY-MM-DD` section,原 [Unreleased] 下的条目自然归到新版本。
#
# 前置一次性:
#   brew install gh && gh auth login
#   xcrun notarytool store-credentials "cc-dashboard-notary" --key <p8> --key-id <...> --issuer <...>
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys   # 生成 EdDSA 私钥到 keychain

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# ---------- arg parsing ----------
VERSION=""
DRY_RUN=0
SKIP_NOTARIZE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)       DRY_RUN=1;       shift ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*) echo "Unknown flag: $1" >&2; exit 1 ;;
        *)
            if [[ -z "$VERSION" ]]; then VERSION="$1"
            else echo "Unexpected arg: $1" >&2; exit 1
            fi
            shift
            ;;
    esac
done

step() { echo ""; echo "==> [Step $1] $2"; }
fail() { echo "" >&2; echo "Error: $*" >&2; exit 1; }

# 无参数 → 读 Info.plist 当前版本,patch+1。minor/major 必须手动指定。
if [[ -z "$VERSION" ]]; then
    CUR=$(plutil -extract CFBundleShortVersionString raw Info.plist 2>/dev/null) \
        || fail "无法读取 Info.plist 的 CFBundleShortVersionString"
    if [[ "$CUR" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
        echo "==> 无参自动 bump patch: $CUR → $VERSION"
        echo "    (minor/major 请显式: $0 <X.Y.Z>)"
    else
        fail "当前版本 '$CUR' 不是 semver,无法自动 bump。请显式: $0 <X.Y.Z>"
    fi
fi

# ---------- preflight ----------
step 0 "preflight checks"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version '$VERSION' 不是 semver 格式 (X.Y.Z)"

# working tree 干净(防止带 uncommitted 改动污染 version-bump commit)
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    fail "working tree 有 uncommitted 改动,先 commit 或 stash"
fi
if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    fail "working tree 有 untracked 文件,先 commit / 删除 / 加 .gitignore"
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ "$BRANCH" == "main" ]] || fail "当前在分支 '$BRANCH',只允许从 main 发版"

[[ -z "$(git tag -l "v$VERSION")" ]] || fail "tag v$VERSION 已存在"

command -v gh >/dev/null 2>&1 || fail "gh CLI 未装,跑: brew install gh && gh auth login"
gh auth status >/dev/null 2>&1  || fail "gh 未登录,跑: gh auth login"

if grep -q "<title>Version $VERSION</title>" docs/appcast.xml 2>/dev/null; then
    fail "docs/appcast.xml 已有 Version $VERSION 的 item"
fi

echo "preflight OK"

# ---------- Step 1: bump Info.plist ----------
step 1 "bump Info.plist to $VERSION"
OLD_BUILD=$(plutil -extract CFBundleVersion raw Info.plist)
if ! [[ "$OLD_BUILD" =~ ^[0-9]+$ ]]; then
    fail "CFBundleVersion 不是整数 ('$OLD_BUILD'),不知道怎么自增"
fi
NEW_BUILD=$((OLD_BUILD + 1))
plutil -replace CFBundleShortVersionString -string "$VERSION" Info.plist
plutil -replace CFBundleVersion -string "$NEW_BUILD" Info.plist
echo "CFBundleShortVersionString=$VERSION, CFBundleVersion=$NEW_BUILD (was $OLD_BUILD)"

# ---------- Step 1.5: promote CHANGELOG [Unreleased] → [X] ----------
# [Unreleased] 标题保留(下一版还会用),下面插入新的 [X] — DATE section。
# 开发期间加在 [Unreleased] 下的条目现在自然归属 [X]。
# 底部的 compare-link 也一并更新,加上 [X] 的 release tag 链接。
step 1.5 "promote CHANGELOG [Unreleased] → [$VERSION]"
if [[ -f CHANGELOG.md ]] && grep -q '^## \[Unreleased\]$' CHANGELOG.md; then
    TODAY=$(date +%F)
    awk -v v="$VERSION" -v d="$TODAY" '
        !done && /^## \[Unreleased\]$/ {
            print; print ""; print "## [" v "] — " d; done=1; next
        }
        { print }
    ' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

    # compare-link:[Unreleased]: .../compare/v<old>...HEAD  →  .../compare/v<new>...HEAD
    # 并在下一行插入  [<new>]: .../releases/tag/v<new>
    python3 - "$VERSION" CHANGELOG.md <<'PY'
import re, sys, pathlib
version = sys.argv[1]
path = pathlib.Path(sys.argv[2])
text = path.read_text()
def repl(m):
    base = m.group(1)
    return (f"[Unreleased]: {base}compare/v{version}...HEAD\n"
            f"[{version}]: {base}releases/tag/v{version}")
new = re.sub(r"^\[Unreleased\]: (.*?)compare/v[0-9.]+\.\.\.HEAD$",
             repl, text, count=1, flags=re.M)
path.write_text(new)
PY

    echo "CHANGELOG: [Unreleased] → [$VERSION] — $TODAY"
else
    echo "(CHANGELOG.md 缺失或没有 [Unreleased] section — 跳过)"
fi

# ---------- Step 2: commit version bump + CHANGELOG ----------
step 2 "commit version bump"
git add Info.plist
[[ -f CHANGELOG.md ]] && git add CHANGELOG.md
git commit -m "Bump version to $VERSION"

# ---------- Step 3: build + (optional) notarize ----------
step 3 "build + notarize"
if (( SKIP_NOTARIZE )); then
    echo "(--skip-notarize: building without notarization)"
    ./make-bundle.sh
else
    CC_NOTARIZE=1 ./make-bundle.sh
fi

# ---------- Step 4: smoke test ----------
step 4 "smoke test signed app"
codesign --verify --strict --deep dist/cc-dashboard.app
SMOKE_OUT=$(timeout 3 dist/cc-dashboard.app/Contents/MacOS/CCDashboard 2>&1 || true)
if echo "$SMOKE_OUT" | grep -q "Library not loaded"; then
    echo "$SMOKE_OUT" >&2
    fail "dyld cannot load a framework — 检查 Sparkle/Firebase frameworks 是否正确嵌入 + 签名"
fi
echo "signature OK, dyld OK"

if (( !SKIP_NOTARIZE )); then
    if ! spctl -a -vvv --type install dist/cc-dashboard.dmg 2>&1 | grep -q "accepted"; then
        fail "DMG 没过 Gatekeeper — notarize / staple 可能失败"
    fi
    echo "notarization accepted"
fi

# ---------- Step 5: update appcast + cask ----------
step 5 "update appcast + cask"
if (( SKIP_NOTARIZE )); then
    echo "(--skip-notarize: 没分发产物,跳过 appcast/cask 更新)"
    DMG_SHA="<skipped>"
else
    ./scripts/update_appcast.sh --in-place dist/cc-dashboard.dmg
    DMG_SHA=$(shasum -a 256 dist/cc-dashboard.dmg | awk '{print $1}')
    # 用 | 做分隔符避开 version 里的 .
    sed -i '' -E "s|version \"[^\"]+\"|version \"$VERSION\"|" homebrew-cask/Casks/cc-dashboard.rb
    sed -i '' -E "s|sha256 \"[^\"]+\"|sha256 \"$DMG_SHA\"|" homebrew-cask/Casks/cc-dashboard.rb
    echo "cask: version=$VERSION sha256=$DMG_SHA"
fi

# ---------- Step 6: commit distribution metadata + tag ----------
step 6 "commit distribution + tag v$VERSION"
if (( !SKIP_NOTARIZE )); then
    git add docs/appcast.xml homebrew-cask/Casks/cc-dashboard.rb
    if git diff --cached --quiet; then
        echo "(no distribution metadata changes)"
    else
        git commit -m "v$VERSION: appcast + cask"
    fi
fi
git tag "v$VERSION"

if (( DRY_RUN )); then
    echo ""
    echo "==> --dry-run: 停在这里。本地状态:"
    echo "   Info.plist: $VERSION (build $NEW_BUILD)"
    echo "   DMG sha256: $DMG_SHA"
    echo "   git tag v$VERSION (本地,未推)"
    echo ""
    echo "回滚本地改动:"
    echo "   git tag -d v$VERSION"
    echo "   git reset --hard HEAD~2   # 撤两个 commit (bump + distribution)"
    exit 0
fi

# ---------- Step 7: push main + tag ----------
step 7 "push main + tag"
git push origin main
git push origin "v$VERSION"

# ---------- Step 8: GitHub Release + DMG upload ----------
step 8 "create GitHub Release v$VERSION"
PREV_TAG=$(git describe --tags --abbrev=0 "v$VERSION^" 2>/dev/null || echo "")
if [[ -n "$PREV_TAG" ]]; then
    NOTES=$(git log "$PREV_TAG..v$VERSION" --pretty='- %s' | grep -vE '^- (Bump|v[0-9]+\.[0-9]+\.[0-9]+:)' || true)
else
    NOTES=$(git log "v$VERSION" --pretty='- %s' -20 | grep -vE '^- (Bump|v[0-9]+\.[0-9]+\.[0-9]+:)' | head -15 || true)
fi
[[ -z "$NOTES" ]] && NOTES="Release v$VERSION"

if gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "Release v$VERSION 已存在 — 追加/覆盖 DMG"
    gh release upload "v$VERSION" dist/cc-dashboard.dmg --clobber
else
    gh release create "v$VERSION" dist/cc-dashboard.dmg \
        --title "v$VERSION" \
        --notes "$NOTES"
fi

# ---------- Step 9: sync tap repo ----------
step 9 "sync tap repo"
TAP_DIR=".build/tap/homebrew-cc-dashboard"
if [[ ! -d "$TAP_DIR/.git" ]]; then
    mkdir -p "$(dirname "$TAP_DIR")"
    git clone git@github.com:heypandax/homebrew-cc-dashboard.git "$TAP_DIR"
else
    git -C "$TAP_DIR" fetch origin main
    git -C "$TAP_DIR" reset --hard origin/main
fi
mkdir -p "$TAP_DIR/Casks"
cp homebrew-cask/Casks/cc-dashboard.rb "$TAP_DIR/Casks/"
git -C "$TAP_DIR" add -A
if git -C "$TAP_DIR" diff --cached --quiet; then
    echo "tap 仓已是最新,无需 push"
else
    git -C "$TAP_DIR" commit -m "cc-dashboard v$VERSION"
    git -C "$TAP_DIR" push origin main
    echo "tap 仓已同步"
fi

# ---------- Step 10: verify Pages appcast ----------
step 10 "verify GitHub Pages appcast"
APPCAST_URL="https://heypandax.github.io/cc-dashboard/appcast.xml"
for i in 1 2 3; do
    if curl -sSf -I "$APPCAST_URL" 2>&1 | head -1 | grep -qE "200|304"; then
        echo "$APPCAST_URL 200"
        break
    fi
    if (( i == 3 )); then
        echo "Warning: $APPCAST_URL 还没 200(GitHub Pages rebuild 最多要 1-2 分钟,稍后自己 curl 重试即可)" >&2
    else
        echo "(retry $i/3: Pages rebuild 还没完,sleep 15s)"
        sleep 15
    fi
done

echo ""
echo "==> DONE: v$VERSION released 🚀"
echo ""
echo "新用户:"
echo "  brew tap heypandax/cc-dashboard"
echo "  brew install --cask cc-dashboard"
echo ""
echo "老用户:"
echo "  brew upgrade --cask cc-dashboard"
echo "  # 或 app 内菜单 'Check for Updates…' 走 Sparkle"
