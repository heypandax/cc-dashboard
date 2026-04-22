#!/bin/bash
# PreToolUse hook wrapper
#   1. 先 /health check (2s):cc-dashboard 挂了就立刻 fallback ask,不让 Claude CLI 白等
#   2. 活 → 长等决策(最长 600s,够你离开电脑去倒杯咖啡回来再 allow)
#   3. 超时也 fallback ask,走 Claude Code 原生 TUI
set -u

INPUT=$(cat)
BASE="http://127.0.0.1:7788"

fallback_ask() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"$reason"}}
EOF
    exit 0
}

# Health check:活着才挂长 timeout,挂了直接 fallback
if ! curl -sS -o /dev/null -m 2 "$BASE/health" 2>/dev/null; then
    fallback_ask "cc-dashboard unavailable"
fi

RESPONSE=$(curl -sS -X POST "$BASE/hook/pre-tool-use" \
    -H "Content-Type: application/json" \
    -d "$INPUT" \
    --max-time 600 \
    2>/dev/null) || RESPONSE=""

if [[ -z "$RESPONSE" ]]; then
    fallback_ask "cc-dashboard response timeout (>600s)"
fi

echo "$RESPONSE"
exit 0
