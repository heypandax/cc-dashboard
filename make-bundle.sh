#!/bin/bash
# 把 swift build 出的 executable 打成 macOS .app bundle
# 用法:./make-bundle.sh [Debug|Release]  (默认 Release)

set -euo pipefail

CONFIG="${1:-Release}"
CONFIG_LOWER=$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="cc-dashboard"
BUNDLE_NAME="${APP_NAME}.app"
DIST_DIR="dist"
BUNDLE_PATH="${DIST_DIR}/${BUNDLE_NAME}"
EXECUTABLE="CCDashboard"

echo "==> Building ($CONFIG)"
if [[ "$CONFIG_LOWER" == "release" ]]; then
    swift build -c release
    BUILD_DIR=".build/release"
else
    swift build
    BUILD_DIR=".build/debug"
fi

APPICON_BUNDLE="design/AppIcon.icon"
APPICON_ICNS="$DIST_DIR/AppIcon.icns"
APPICON_CAR="$DIST_DIR/Assets.car"

# 从 Icon Composer 产出的 .icon bundle 编译 Liquid Glass Assets.car + 兼容 .icns。
# 这是 macOS 26 Tahoe 唯一让通知 / 系统 UI 不套 white container 的方式(Apple 官方格式)。
if [[ ! -d "$APPICON_BUNDLE" ]]; then
    echo "Error: $APPICON_BUNDLE not found. Use Xcode's Icon Composer to create it." >&2
    exit 1
fi

if [[ ! -f "$APPICON_ICNS" ]] || [[ ! -f "$APPICON_CAR" ]] || \
   [[ "$APPICON_BUNDLE/icon.json" -nt "$APPICON_ICNS" ]]; then
    echo "==> Compiling $APPICON_BUNDLE via actool (Liquid Glass + .icns fallback)"
    mkdir -p "$DIST_DIR"
    WORK=$(mktemp -d)
    xcrun actool "$APPICON_BUNDLE" --compile "$WORK" \
        --platform macosx --minimum-deployment-target 14.0 \
        --app-icon AppIcon --include-all-app-icons \
        --enable-on-demand-resources NO \
        --target-device mac \
        --output-partial-info-plist "$WORK/actool-partial.plist" >/dev/null
    cp "$WORK/Assets.car"   "$APPICON_CAR"
    cp "$WORK/AppIcon.icns" "$APPICON_ICNS"
    rm -rf "$WORK"
fi

echo "==> Assembling .app bundle at $BUNDLE_PATH"
rm -rf "$BUNDLE_PATH"
mkdir -p "$BUNDLE_PATH/Contents/MacOS"
mkdir -p "$BUNDLE_PATH/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE" "$BUNDLE_PATH/Contents/MacOS/$EXECUTABLE"
cp "Info.plist" "$BUNDLE_PATH/Contents/Info.plist"
cp "$APPICON_ICNS" "$BUNDLE_PATH/Contents/Resources/AppIcon.icns"
cp "$APPICON_CAR"  "$BUNDLE_PATH/Contents/Resources/Assets.car"

# 本地化资源:拷每个 .lproj 目录(Localizable.strings 等)到 bundle Resources。
# Bundle.main 按当前 locale 自动查找 —— SwiftUI Text 里的 literal 字符串会被
# 自动 localize,不需要业务代码改。
if [[ -d "Resources" ]]; then
    for lproj in Resources/*.lproj; do
        [[ -d "$lproj" ]] && cp -R "$lproj" "$BUNDLE_PATH/Contents/Resources/"
    done
fi

# Firebase configuration(本地未配置时 warn 一下继续跑,app 里 configure() 会 fatalError)
if [[ -f "GoogleService-Info.plist" ]]; then
    cp "GoogleService-Info.plist" "$BUNDLE_PATH/Contents/Resources/"
else
    echo "Warning: GoogleService-Info.plist not found at project root; Firebase will not initialize" >&2
fi

# Hook 脚本进 bundle,启动时由 HooksInstaller 复制到 ~/Library/Application Support/cc-dashboard/hooks/
mkdir -p "$BUNDLE_PATH/Contents/Resources/hooks"
cp hooks/pretool.sh hooks/lifecycle.sh "$BUNDLE_PATH/Contents/Resources/hooks/"
chmod +x "$BUNDLE_PATH/Contents/Resources/hooks/pretool.sh" \
         "$BUNDLE_PATH/Contents/Resources/hooks/lifecycle.sh"

# Sparkle.framework 嵌入:SwiftPM 把它产到 $BUILD_DIR/,手组 bundle 时必须显式拷过来,
# 否则 runtime dyld 链接失败,app 启动即崩(codesign --verify 不会抓到这个)。
mkdir -p "$BUNDLE_PATH/Contents/Frameworks"
cp -R "$BUILD_DIR/Sparkle.framework" "$BUNDLE_PATH/Contents/Frameworks/"

# 分级签名:Sparkle 的内部 helpers(XPC / Updater.app / Autoupdate)必须独立签成
# hardened runtime,且不带 app entitlements。**不用 --deep** —— --deep 会把 main app
# 的 entitlements 覆盖到 Sparkle 子组件,runtime 拒绝加载。顺序:内 → 外。
#
# cc-dashboard.entitlements 关于 entitlements 选择的解释:
#   * app 不走 sandbox(没有 com.apple.security.app-sandbox)。hardened runtime 靠
#     codesign --options runtime 加。
#   * network.server:绑 127.0.0.1:7788 接收 Claude Code PreToolUse hook 和
#     本地 WebSocket 客户端连接。
#   * network.client:出向 Apple notary / Sparkle appcast / Firebase Analytics / Crashlytics。
#   * 不请求 filesystem / keychain / camera / mic / IPC。
# 注:entitlements 文件里**不能**写 XML 注释 —— Apple AMFI 的 XML parser 不接受,
#     会让 codesign 报 "Failed to parse entitlements: AMFIUnserializeXML: syntax error"。
SIGN_IDENTITY="${CC_SIGN_IDENTITY:-Developer ID Application: lee davin (SC9S2SJ42G)}"
SPK_FW="$BUNDLE_PATH/Contents/Frameworks/Sparkle.framework"
SPK_INNER=(
    "$SPK_FW/Versions/B/XPCServices/Downloader.xpc"
    "$SPK_FW/Versions/B/XPCServices/Installer.xpc"
    "$SPK_FW/Versions/B/Updater.app"
    "$SPK_FW/Versions/B/Autoupdate"
    "$SPK_FW"
)

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> Ad-hoc codesigning Sparkle internals"
    for path in "${SPK_INNER[@]}"; do
        codesign --force --sign - "$path"
    done
    echo "==> Ad-hoc codesigning main app"
    codesign --force --sign - \
        --entitlements "cc-dashboard.entitlements" \
        "$BUNDLE_PATH"
else
    echo "==> Signing Sparkle internals with: $SIGN_IDENTITY"
    for path in "${SPK_INNER[@]}"; do
        codesign --force --sign "$SIGN_IDENTITY" \
            --timestamp --options runtime \
            "$path"
    done
    echo "==> Signing main app with: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" \
        --timestamp --options runtime \
        --entitlements "cc-dashboard.entitlements" \
        "$BUNDLE_PATH"
fi

echo "==> Verifying signature"
codesign --verify --strict --deep --verbose=2 "$BUNDLE_PATH"
codesign -dv --verbose=2 "$BUNDLE_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp"

# Crashlytics dSYM 上传:有 GoogleService-Info.plist 且 SDK 带的 upload-symbols 可找到时执行。
# 本地 debug build (没 .dSYM) 会 skip;没配置 Firebase 也 skip,不阻塞开发。
# 先试固定路径(SwiftPM 约定位置),找不到再 find 兜底(Firebase SDK 升级可能搬家)。
UPLOAD_SYMBOLS=".build/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols"
if [[ ! -x "$UPLOAD_SYMBOLS" ]]; then
    UPLOAD_SYMBOLS=$(find .build -name upload-symbols -type f -perm -111 2>/dev/null | head -1)
fi
DSYM_PATH="$BUILD_DIR/$EXECUTABLE.dSYM"
if [[ -n "$UPLOAD_SYMBOLS" && -f "GoogleService-Info.plist" && -d "$DSYM_PATH" ]]; then
    echo "==> Uploading dSYMs to Firebase Crashlytics"
    "$UPLOAD_SYMBOLS" -gsp GoogleService-Info.plist -p mac "$DSYM_PATH" || \
        echo "Warning: upload-symbols failed (non-fatal)" >&2
fi

# 公证(CC_NOTARIZE=1 触发):打 DMG → 签 DMG → 上传 Apple notary → staple 票据
if [[ "${CC_NOTARIZE:-0}" == "1" ]]; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "Error: ad-hoc 签名无法公证,请先设置 CC_SIGN_IDENTITY" >&2
        exit 1
    fi

    NOTARY_PROFILE="${CC_NOTARY_PROFILE:-cc-dashboard-notary}"
    DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
    VOLNAME="cc-dashboard"

    echo ""
    echo "==> Building DMG (with /Applications shortcut for drag-install)"
    STAGE=$(mktemp -d)
    cp -R "$BUNDLE_PATH" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG_PATH"
    hdiutil create \
        -srcfolder "$STAGE" \
        -volname "$VOLNAME" \
        -format UDZO \
        -fs HFS+ \
        -ov \
        "$DMG_PATH" >/dev/null
    rm -rf "$STAGE"

    echo "==> Signing DMG"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

    echo "==> Submitting to Apple notary service (typically 1-5 min)"
    # CI 用 API Key 三件套(secrets 导出的 .p8 文件),本地用 keychain profile
    if [[ -n "${APPLE_API_KEY_PATH:-}" ]]; then
        xcrun notarytool submit "$DMG_PATH" \
            --key "$APPLE_API_KEY_PATH" \
            --key-id "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID required when APPLE_API_KEY_PATH is set}" \
            --issuer "${APPLE_API_ISSUER:?APPLE_API_ISSUER required when APPLE_API_KEY_PATH is set}" \
            --wait
    else
        xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    fi

    echo "==> Stapling ticket to DMG"
    xcrun stapler staple "$DMG_PATH"

    echo ""
    echo "==> Final Gatekeeper assessment (expect 'accepted')"
    spctl -a -vvv --type install "$DMG_PATH"

    echo ""
    echo "==> Done: $BUNDLE_PATH"
    echo "    Distributable DMG: $DMG_PATH"
    echo ""
    echo "==> Next: generate Sparkle appcast <item> for this DMG:"
    echo "    ./scripts/update_appcast.sh \"$DMG_PATH\""
    echo "    (requires swift package resolve + EdDSA keys in keychain via generate_keys)"
else
    echo ""
    echo "==> Gatekeeper assessment (expect 'rejected' before notarization)"
    spctl -a -vvv --type execute "$BUNDLE_PATH" 2>&1 || true

    echo ""
    echo "==> Done: $BUNDLE_PATH"
    echo "    Run: open $BUNDLE_PATH"
    echo "    Notarize + distribute: CC_NOTARIZE=1 ./make-bundle.sh"
fi
