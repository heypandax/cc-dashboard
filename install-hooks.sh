#!/bin/bash
# 幂等安装/卸载 cc-dashboard 的 Claude Code hooks。保留现有 hooks(如 ip-guard.sh)。
# 用法:
#   ./install-hooks.sh              # 安装(幂等)
#   ./install-hooks.sh --uninstall  # 卸载
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_HOOKS="$SCRIPT_DIR/hooks"
# 固定安装目录 —— 跟 app 里 HooksInstaller 用同一路径,两条路径完全兼容
INSTALL_DIR="$HOME/Library/Application Support/cc-dashboard/hooks"
SETTINGS="${HOME}/.claude/settings.json"

UNINSTALL=false
if [[ "${1:-}" == "--uninstall" ]]; then
    UNINSTALL=true
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required. Install with: brew install jq" >&2
    exit 1
fi

if [[ ! -f "$SETTINGS" ]]; then
    echo "Error: $SETTINGS not found. Run Claude Code at least once to create it." >&2
    exit 1
fi

# 把 hook 脚本复制到固定安装目录(app 也装到这里 → 路径完全一致)
mkdir -p "$INSTALL_DIR"
chmod +x "$SOURCE_HOOKS/pretool.sh" "$SOURCE_HOOKS/lifecycle.sh"
cp "$SOURCE_HOOKS/pretool.sh" "$SOURCE_HOOKS/lifecycle.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/pretool.sh" "$INSTALL_DIR/lifecycle.sh"

# 备份
BACKUP="${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "Backup: $BACKUP"

# 写入 settings.json 的 command 字段必须 shell-quote —— Application Support 路径含空格,
# 不 quote 的话 `/bin/sh -c <command>` 执行时会按空格 split 出错。
PRETOOL_PATH="$INSTALL_DIR/pretool.sh"
LIFECYCLE_PATH="$INSTALL_DIR/lifecycle.sh"
PRETOOL="'$PRETOOL_PATH'"
LIFECYCLE="'$LIFECYCLE_PATH'"

# 移除旧 cc-dashboard hook:识别 quoted/unquoted 当前路径 + legacy(任意 */hooks/pretool.sh 且含 cc-dashboard)。
# unquoted 形态是历史 bug 遗留,需要能清掉以完成自动修复。
# heredoc 用 'JQ' 避免 shell 展开,jq 脚本里可以自由用单引号字面量。
strip_cc_dashboard() {
    local script
    script=$(cat <<'JQ'
def is_cc_cmd(c):
    (c == $pretool_path)
    or (c == "'" + $pretool_path + "'")
    or (c | startswith($lifecycle_path + " "))
    or (c | startswith("'" + $lifecycle_path + "' "))
    or ((c | endswith("/hooks/pretool.sh")) and (c | contains("cc-dashboard")))
    or ((c | endswith("/hooks/pretool.sh'")) and (c | contains("cc-dashboard")))
    or ((c | contains("/hooks/lifecycle.sh ")) and (c | contains("cc-dashboard")))
    or ((c | contains("/hooks/lifecycle.sh' ")) and (c | contains("cc-dashboard")));
if .hooks then
    .hooks |= with_entries(
        .value |= (
            map(.hooks |= map(select(is_cc_cmd(.command) | not)))
            | map(select(.hooks | length > 0))
        )
    ) | .hooks |= with_entries(select(.value | length > 0))
else . end
JQ
)
    jq --arg pretool_path "$PRETOOL_PATH" \
       --arg lifecycle_path "$LIFECYCLE_PATH" \
       "$script" "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
}

upsert_hook() {
    local EVENT="$1"
    local COMMAND="$2"
    local MATCHER="$3"
    local TIMEOUT="${4:-30}"

    local NEW_ENTRY
    if [[ -n "$MATCHER" ]]; then
        NEW_ENTRY=$(jq -n --arg matcher "$MATCHER" --arg cmd "$COMMAND" --argjson timeout "$TIMEOUT" \
            '{matcher: $matcher, hooks: [{type: "command", command: $cmd, timeout: $timeout}]}')
    else
        NEW_ENTRY=$(jq -n --arg cmd "$COMMAND" --argjson timeout "$TIMEOUT" \
            '{hooks: [{type: "command", command: $cmd, timeout: $timeout}]}')
    fi

    jq --arg event "$EVENT" --argjson entry "$NEW_ENTRY" '
        .hooks //= {} |
        .hooks[$event] //= [] |
        .hooks[$event] += [$entry]
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
}

echo "==> Removing any previous cc-dashboard hooks"
strip_cc_dashboard

if $UNINSTALL; then
    echo "==> Uninstalled cc-dashboard hooks"
    echo "    (existing non-cc-dashboard hooks preserved)"
    exit 0
fi

echo "==> Installing cc-dashboard hooks"
upsert_hook "PreToolUse"   "$PRETOOL"                       "Bash|Edit|Write|MultiEdit|WebFetch" 605
upsert_hook "SessionStart" "$LIFECYCLE session-start"        "" 10
upsert_hook "Stop"         "$LIFECYCLE stop"                 "" 10
upsert_hook "SessionEnd"   "$LIFECYCLE session-end"          "" 10
upsert_hook "Notification" "$LIFECYCLE notification"         "" 10

echo "==> Done. Hooks installed to: $SETTINGS"
echo "    PreToolUse matcher: Bash|Edit|Write|MultiEdit|WebFetch (read-only tools pass through)"
echo "    Uninstall: $0 --uninstall"
