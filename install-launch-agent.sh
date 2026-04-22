#!/bin/bash
# 安装/卸载 cc-dashboard LaunchAgent(开机自启)
# 用法:
#   ./install-launch-agent.sh              # 安装
#   ./install-launch-agent.sh --uninstall  # 卸载
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$SCRIPT_DIR/dist/cc-dashboard.app"
LABEL="com.heypanda.cc-dashboard"
PLIST_SRC="$SCRIPT_DIR/LaunchAgent.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/cc-dashboard"

UNINSTALL=false
[[ "${1:-}" == "--uninstall" ]] && UNINSTALL=true

if $UNINSTALL; then
    if [[ -f "$PLIST_DST" ]]; then
        launchctl unload "$PLIST_DST" 2>/dev/null || true
        rm "$PLIST_DST"
        echo "Uninstalled LaunchAgent: $PLIST_DST"
    else
        echo "No LaunchAgent at $PLIST_DST"
    fi
    exit 0
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: $APP_PATH not found. Run ./make-bundle.sh first." >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

# Escape for sed (APP_PATH/LOG_DIR contain /)
APP_PATH_ESC=$(printf '%s\n' "$APP_PATH" | sed -e 's/[\/&]/\\&/g')
LOG_DIR_ESC=$(printf '%s\n' "$LOG_DIR" | sed -e 's/[\/&]/\\&/g')

sed -e "s/__APP_PATH__/$APP_PATH_ESC/g" \
    -e "s/__LOG_DIR__/$LOG_DIR_ESC/g" \
    "$PLIST_SRC" > "$PLIST_DST"

# Reload
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

echo "Installed LaunchAgent: $PLIST_DST"
echo "Logs:  $LOG_DIR/cc-dashboard.{out,err}.log"
echo "Stop:  launchctl unload $PLIST_DST"
