#!/bin/bash
# Lifecycle hook wrapper(SessionStart/Stop/SessionEnd/Notification/UserPromptSubmit):fire-and-forget
# 把 stdin JSON 发给 cc-dashboard,不管响应。永远 exit 0 不阻塞 Claude Code。
set -u

EVENT="${1:-}"
INPUT=$(cat)

case "$EVENT" in
    session-start)      PATH_SEG="session-start" ;;
    stop)               PATH_SEG="stop" ;;
    session-end)        PATH_SEG="session-end" ;;
    notification)       PATH_SEG="notification" ;;
    user-prompt-submit) PATH_SEG="user-prompt-submit" ;;
    *)                  exit 0 ;;
esac

# 最多等 3s(cc-dashboard 若未启动,立即失败)
curl -sS -X POST "http://127.0.0.1:7788/hook/${PATH_SEG}" \
    -H "Content-Type: application/json" \
    -d "$INPUT" \
    --max-time 3 \
    -o /dev/null \
    2>/dev/null || true

exit 0
