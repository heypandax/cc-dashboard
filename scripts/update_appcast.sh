#!/bin/bash
# Sparkle appcast <item> 生成器。
# 用法:
#   ./scripts/update_appcast.sh <dmg_path>              # 打印到 stdout,手工粘贴
#   ./scripts/update_appcast.sh --in-place <dmg_path>   # 自动插入 docs/appcast.xml 的 <channel> 顶部
#
# 前置:
#   1. EdDSA 私钥已存 keychain(首次通过 generate_keys 生成)
#   2. 要么 swift package resolve 过 Sparkle 依赖(sign_update 在 .build/ 下),
#      要么 brew install --cask sparkle(走 GUI 版里带的 sign_update)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

IN_PLACE=0
if [[ "${1:-}" == "--in-place" ]]; then
    IN_PLACE=1
    shift
fi

DMG_PATH="${1:?usage: $0 [--in-place] <dmg_path>}"
if [[ ! -f "$DMG_PATH" ]]; then
    echo "Error: DMG not found at $DMG_PATH" >&2
    exit 1
fi

GITHUB_REPO="heypandax/cc-dashboard"
INFO_PLIST="Info.plist"

VERSION=$(plutil -extract CFBundleShortVersionString raw -- "$INFO_PLIST")
BUILD=$(plutil -extract CFBundleVersion raw -- "$INFO_PLIST")
DMG_NAME=$(basename "$DMG_PATH")

# 定位 sign_update:SPM artifacts 下 EdDSA 版本(排除 old_dsa_scripts 遗留),再 Homebrew Sparkle.app,最后 PATH
SIGN_UPDATE=""
for candidate in \
    $(find .build -name sign_update -type f -not -path '*/old_dsa_scripts/*' 2>/dev/null) \
    "/Applications/Sparkle.app/Contents/Resources/sign_update"
do
    if [[ -x "$candidate" ]]; then
        SIGN_UPDATE="$candidate"; break
    fi
done
if [[ -z "$SIGN_UPDATE" ]] && command -v sign_update >/dev/null 2>&1; then
    SIGN_UPDATE="$(command -v sign_update)"
fi
if [[ -z "$SIGN_UPDATE" ]]; then
    echo "Error: sign_update not found." >&2
    echo "  先跑 'swift package resolve' 或 'brew install --cask sparkle'。" >&2
    exit 1
fi

# CI 走 SPARKLE_KEY_FILE env(secret 解码到临时文件),本地默认走 keychain
# sign_update 输出形如:sparkle:edSignature="..." length="..."
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    SIG_LINE=$("$SIGN_UPDATE" -f "$SPARKLE_KEY_FILE" "$DMG_PATH")
else
    SIG_LINE=$("$SIGN_UPDATE" "$DMG_PATH")
fi

ENCLOSURE_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$DMG_NAME"
PUB_DATE=$(LC_ALL=en_US.UTF-8 date -u +"%a, %d %b %Y %H:%M:%S +0000")

ITEM_XML="        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url=\"$ENCLOSURE_URL\"
                type=\"application/octet-stream\"
                $SIG_LINE />
        </item>"

if (( IN_PLACE )); then
    APPCAST="docs/appcast.xml"
    if [[ ! -f "$APPCAST" ]]; then
        echo "Error: $APPCAST not found" >&2
        exit 1
    fi
    # 幂等:已含该版本就拒绝插入,避免重复 <item>
    if grep -q "<title>Version $VERSION</title>" "$APPCAST"; then
        echo "Error: $APPCAST 已有 Version $VERSION 的 <item>,拒绝重复插入" >&2
        exit 1
    fi
    # 在第一处 </language> 之后插入,保持最新版在 <channel> 顶。
    # 用 sed `r` 从文件读 item(macos-26 runner 的 awk 不接受 -v 传 multi-line string)。
    ITEM_FILE=$(mktemp -t cc-appcast-item)
    printf '%s\n' "$ITEM_XML" > "$ITEM_FILE"
    sed "/<\/language>/r $ITEM_FILE" "$APPCAST" > "$APPCAST.tmp" && mv "$APPCAST.tmp" "$APPCAST"
    rm -f "$ITEM_FILE"
    echo "==> Inserted Version $VERSION into $APPCAST"
else
    cat <<EOF

# 把下面整段 <item> 粘进 docs/appcast.xml 的 <channel>...</channel> 内最顶上,
# 然后 commit + push docs/ 到 main(触发 GitHub Pages 刷新):

$ITEM_XML

EOF
fi
