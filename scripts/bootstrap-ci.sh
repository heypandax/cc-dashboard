#!/bin/bash
# 一键把本机发版凭据搬到 GitHub Actions Secrets,覆盖 8 条需要的 secret。
#
# 全自动部分:
#   - KEYCHAIN_PASSWORD / 临时 p12 密码(openssl rand)
#   - MACOS_CERTIFICATE (security export → base64)
#   - SPARKLE_PRIVATE_KEY (generate_keys -x → base64)
#   - gh secret set * 全自动上传
#
# 必须你介入的 3 处:
#   - gh auth(如果还没登)→ 浏览器 OAuth
#   - ASC API p8 路径 + KEY_ID + ISSUER(脚本会 prompt,找不到 p8 可以粘路径)
#   - TAP_REPO_TOKEN(GitHub fine-grained PAT,浏览器生成后粘回)
#
# 用法:./scripts/bootstrap-ci.sh
# 重跑:安全,已存在的 secret 会被覆盖(gh secret set 默认行为)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

step()  { echo ""; echo "==> $*"; }
info()  { echo "    $*"; }
fail()  { echo "" >&2; echo "Error: $*" >&2; exit 1; }
prompt() {
    # prompt <varname> <message> [--secret]
    local var="$1" msg="$2" secret="${3:-}"
    local val
    if [[ "$secret" == "--secret" ]]; then
        read -rs -p "    $msg: " val
        echo
    else
        read -r  -p "    $msg: " val
    fi
    printf -v "$var" '%s' "$val"
}

OWNER_REPO="heypandax/cc-dashboard"
TAP_REPO="heypandax/homebrew-cc-dashboard"
CERT_CN="Developer ID Application: lee davin (SC9S2SJ42G)"
SPARKLE_GENKEYS=".build/artifacts/sparkle/Sparkle/bin/generate_keys"

# ---------- 1. preflight ----------
step "preflight"

if ! command -v gh >/dev/null 2>&1; then
    info "gh CLI 未装,尝试 brew 装一下 (需要 1-2 分钟)"
    brew install gh || fail "gh install 失败,手动: brew install gh"
fi

if ! gh auth status >/dev/null 2>&1; then
    info "gh 未登录,跑: gh auth login (选 HTTPS + browser),完事后重跑本脚本"
    exit 1
fi
info "gh OK: $(gh auth status 2>&1 | grep 'Logged in' | head -1 | sed 's/^ *//')"

# 确认当前 repo 是 heypandax/cc-dashboard
CURRENT_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
[[ "$CURRENT_REPO" == "$OWNER_REPO" ]] || fail "当前 repo '$CURRENT_REPO' 不是 $OWNER_REPO,cd 到正确的 repo 再跑"

if [[ ! -x "$SPARKLE_GENKEYS" ]]; then
    info "Sparkle tools 没 resolve,swift package resolve 一下..."
    swift package resolve || fail "swift package resolve 失败"
    [[ -x "$SPARKLE_GENKEYS" ]] || fail "$SPARKLE_GENKEYS 还是不存在"
fi

# 证书在 keychain 里吗?
if ! security find-identity -v -p codesigning | grep -q "$CERT_CN"; then
    fail "keychain 里没找到证书 '$CERT_CN',确认 Developer ID 证书已装"
fi
info "Developer ID 证书 OK"

# ---------- 2. 自动生成密码 ----------
step "generating passwords"
KEYCHAIN_PASSWORD=$(openssl rand -base64 32)
P12_PASSWORD=$(openssl rand -base64 24)
info "KEYCHAIN_PASSWORD / p12 password: 随机生成"

# ---------- 3. 导出 Developer ID .p12 ----------
step "exporting Developer ID certificate to .p12"
P12_PATH="$(mktemp -t cc-dashboard-cert).p12"
trap 'rm -f "$P12_PATH" "${SPARKLE_KEY_PATH:-}" 2>/dev/null' EXIT

# security export:导所有 codesigning identities 成 p12。
# 如果私钥 ACL 是 "Ask for password" 可能弹 GUI 确认——点 "Always Allow"
info "可能弹 'cc-dashboard wants to access keychain' 对话框,点 Always Allow"
if ! security export \
        -k "$HOME/Library/Keychains/login.keychain-db" \
        -t identities -f pkcs12 \
        -P "$P12_PASSWORD" \
        -o "$P12_PATH" 2>/dev/null; then
    # 有些 macOS 版本没 -k 选项,或 login keychain 路径不同
    info "security export 失败,改用 -k 'login.keychain' 重试"
    security export -k login.keychain -t identities -f pkcs12 \
        -P "$P12_PASSWORD" -o "$P12_PATH" || \
        fail "p12 导出失败 —— 可能需要 Keychain Access GUI 手动 Export Items"
fi
info "p12 写入 $P12_PATH"

# ---------- 4. 导出 Sparkle 私钥 ----------
step "exporting Sparkle EdDSA private key"
SPARKLE_KEY_PATH="$(mktemp -t cc-dashboard-sparkle).key"
"$SPARKLE_GENKEYS" -x "$SPARKLE_KEY_PATH" 2>/dev/null || \
    fail "Sparkle 私钥导出失败(keychain 里没私钥?先跑 generate_keys 生成一次)"
info "Sparkle 私钥写入 $SPARKLE_KEY_PATH"

# ---------- 5. 收集 ASC API Key ----------
step "ASC API Key info"

# 尝试自动找 ~/private_keys/AuthKey_*.p8 或 ~/.appstoreconnect/private_keys/
P8_CANDIDATES=(
    $(ls "$HOME/private_keys/AuthKey_"*.p8 2>/dev/null || true)
    $(ls "$HOME/.appstoreconnect/private_keys/AuthKey_"*.p8 2>/dev/null || true)
)
P8_PATH=""
if (( ${#P8_CANDIDATES[@]} > 0 )); then
    P8_PATH="${P8_CANDIDATES[0]}"
    info "自动找到 p8: $P8_PATH"
    prompt confirm "这个 p8 对吗? [Y/n]"
    [[ "$confirm" =~ ^[Nn]$ ]] && P8_PATH=""
fi

if [[ -z "$P8_PATH" ]]; then
    info "找不到 p8。可以:"
    info "  a) 本机有 .p8 文件的话,输入绝对路径"
    info "  b) 去 https://appstoreconnect.apple.com/access/integrations/api 重新生成并下载"
    prompt P8_PATH "ASC API p8 文件路径"
    [[ -f "$P8_PATH" ]] || fail "$P8_PATH 不存在"
fi

# KEY_ID 可以从 p8 文件名抽
DERIVED_KEY_ID=$(basename "$P8_PATH" | sed -E 's/^AuthKey_([^.]+)\.p8$/\1/')
if [[ -n "$DERIVED_KEY_ID" && "$DERIVED_KEY_ID" != "$(basename "$P8_PATH")" ]]; then
    info "从文件名推出 KEY_ID = $DERIVED_KEY_ID"
    APPLE_API_KEY_ID="$DERIVED_KEY_ID"
else
    prompt APPLE_API_KEY_ID "APPLE_API_KEY_ID (10 位字符)"
fi

prompt APPLE_API_ISSUER "APPLE_API_ISSUER (UUID 格式,在 ASC API 页面顶部)"

# ---------- 6. TAP_REPO_TOKEN (PAT) ----------
step "GitHub PAT for tap repo"
PAT_URL="https://github.com/settings/personal-access-tokens/new?type=fine-grained&description=cc-dashboard%20release%20tap%20push&target_name=$(echo $TAP_REPO | tr / _)"
info "必须浏览器生成 PAT。配置:"
info "  • Repository access: Only select → $TAP_REPO"
info "  • Permission: Contents: Read and write"
info "  • Expiration: 1 year"
info ""
info "正在打开浏览器..."
open "$PAT_URL" 2>/dev/null || info "手动访问: $PAT_URL"
prompt TAP_REPO_TOKEN "粘贴 PAT" --secret
[[ "$TAP_REPO_TOKEN" =~ ^github_pat_ ]] || fail "PAT 格式不对(应 github_pat_ 开头)"

# ---------- 7. 上传全部 secrets ----------
step "uploading secrets to $OWNER_REPO"

set_secret() {
    local name="$1" value="$2"
    printf '%s' "$value" | gh secret set "$name" --repo "$OWNER_REPO" >/dev/null
    info "set $name ($(printf '%s' "$value" | wc -c | tr -d ' ') bytes)"
}

set_secret MACOS_CERTIFICATE          "$(base64 -i "$P12_PATH")"
set_secret MACOS_CERTIFICATE_PASSWORD "$P12_PASSWORD"
set_secret KEYCHAIN_PASSWORD          "$KEYCHAIN_PASSWORD"
set_secret APPLE_API_KEY_P8           "$(base64 -i "$P8_PATH")"
set_secret APPLE_API_KEY_ID           "$APPLE_API_KEY_ID"
set_secret APPLE_API_ISSUER           "$APPLE_API_ISSUER"
set_secret SPARKLE_PRIVATE_KEY        "$(base64 -i "$SPARKLE_KEY_PATH")"
set_secret TAP_REPO_TOKEN             "$TAP_REPO_TOKEN"

# ---------- 8. cleanup ----------
step "cleanup"
rm -f "$P12_PATH" "$SPARKLE_KEY_PATH"
info "临时 p12 / Sparkle key 已删"

step "secrets 清单"
gh secret list --repo "$OWNER_REPO"

# ---------- 9. 触发首次 release? ----------
echo ""
info "全部 secrets 就位。下一步触发 workflow:"
info "   gh workflow run Release -f version=0.1.1 --repo $OWNER_REPO"
info "   gh run watch --repo $OWNER_REPO"
echo ""
info "(前提:当前 commit 里含 .github/workflows/release.yml —— 没 push 的话先 push)"
