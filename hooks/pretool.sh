#!/bin/bash
# PreToolUse hook wrapper
#   1. 先 /health check (2s):cc-dashboard 挂了就 silent pass,不让 Claude CLI 白等
#   2. 活 → 长等决策(最长 600s,够你离开电脑去倒杯咖啡回来再 allow)
#   3. 超时也 silent pass,Claude Code 自己走原生 permission 流
#
# silent pass = exit 0 + 空 stdout。Claude Code 把"hook 无输出"当作"无意见",
# 完整保留它原生的授权 UI(包括"项目级始终允许"等多档选项),不会被我们的
# permissionDecision: ask + reason 把 UI 缩成 Yes/No 二选一。
set -u

INPUT=$(cat)
BASE="http://127.0.0.1:7788"

# Health check:活着才挂长 timeout,挂了直接 silent pass
if ! curl -sS -o /dev/null -m 2 "$BASE/health" 2>/dev/null; then
    exit 0
fi

RESPONSE=$(curl -sS -X POST "$BASE/hook/pre-tool-use" \
    -H "Content-Type: application/json" \
    -d "$INPUT" \
    --max-time 600 \
    2>/dev/null) || RESPONSE=""

# 超时(响应空)也 silent pass —— 让 Claude Code 走它自己的 UI 而不是被我们框死
if [[ -z "$RESPONSE" ]]; then
    exit 0
fi

echo "$RESPONSE"
exit 0
