#!/usr/bin/env bash
# notification-proxy.sh — Claude Code Notification Hook（通知代理）
#
# 当 Claude Code 发送通知时（权限提示、空闲提示等），
# 将通知透传给 OpenClaw，让 AGI 感知 Claude Code 的状态。
#
# 触发类型:
#   permission_prompt  — Claude Code 需要权限确认
#   idle_prompt        — Claude Code 空闲等待输入
#   auth_success       — 认证成功
#   elicitation_dialog — MCP 请求用户输入
#
# 环境变量:
#   CC_RESULT_DIR      — 结果目录
#   OPENCLAW_GATEWAY   — Gateway 地址
#   OPENCLAW_TOKEN     — Gateway token
#
# 作者: XuJiaKai

set -euo pipefail

RESULT_DIR="${CC_RESULT_DIR:-$HOME/.openclaw/data/claude-code-results}"
GATEWAY="${OPENCLAW_GATEWAY:-http://127.0.0.1:18789}"
TOKEN="${OPENCLAW_TOKEN:-}"

mkdir -p "$RESULT_DIR"

# ── 读取 Hook 输入 ───────────────────────────────────
INPUT=$(cat)

# ── 解析通知信息 ─────────────────────────────────────
NOTIFICATION_TYPE=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('notification_type', 'unknown'))
" 2>/dev/null || echo "unknown")

MESSAGE=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('message', ''))
" 2>/dev/null || echo "")

TITLE=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('title', ''))
" 2>/dev/null || echo "")

echo "[notification-proxy] 通知类型: $NOTIFICATION_TYPE | $TITLE" >&2

# ── 写入 notification.json ───────────────────────────
echo "$INPUT" | python3 -c "
import json, sys
from datetime import datetime, timezone

data = json.load(sys.stdin)
notif = {
    'hook_event': 'Notification',
    'timestamp': datetime.now(timezone.utc).isoformat(),
    'notification_type': data.get('notification_type', 'unknown'),
    'title': data.get('title', ''),
    'message': data.get('message', ''),
    'session_id': data.get('session_id', ''),
    'cwd': data.get('cwd', '')
}
with open('$RESULT_DIR/notification.json', 'w') as f:
    json.dump(notif, f, indent=2, ensure_ascii=False)
" 2>/dev/null

# ── 发送 Wake Event ──────────────────────────────────
WAKE_TEXT="📢 Claude Code 通知 [$NOTIFICATION_TYPE]: $MESSAGE"

if [ -n "$TOKEN" ]; then
    curl -s -X POST "${GATEWAY}/api/cron/wake" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"text\": $(echo "$WAKE_TEXT" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))"), \"mode\": \"now\"}" \
        >/dev/null 2>&1 || true
elif command -v openclaw &>/dev/null; then
    openclaw system event --text "$WAKE_TEXT" --mode now 2>/dev/null || true
fi

echo "[notification-proxy] 已转发通知到 OpenClaw" >&2
