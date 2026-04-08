#!/usr/bin/env bash
# permission-proxy.sh — Claude Code PermissionRequest Hook（权限代理）
#
# 当 Claude Code 需要权限确认时（如执行命令、写文件），
# 此 Hook 将请求透传给 OpenClaw → 用户，等待响应后返回决策。
#
# 流程:
#   1. 从 stdin 读取 PermissionRequest JSON
#   2. 写入 pending-permission.json（供 OpenClaw 读取）
#   3. 发 wake event 通知 OpenClaw
#   4. 轮询等待 permission-response.json（用户决策）
#   5. 返回 allow/deny JSON 给 Claude Code
#
# 环境变量:
#   CC_RESULT_DIR      — 结果/通信目录，默认 ~/.openclaw/data/claude-code-results
#   CC_PERM_TIMEOUT    — 等待用户响应超时秒数，默认 120
#   CC_PERM_POLL_INTERVAL — 轮询间隔秒数，默认 2
#   OPENCLAW_GATEWAY   — Gateway 地址
#   OPENCLAW_TOKEN     — Gateway token
#
# 作者: XuJiaKai

set -euo pipefail

RESULT_DIR="${CC_RESULT_DIR:-$HOME/.openclaw/data/claude-code-results}"
PENDING_FILE="$RESULT_DIR/pending-permission.json"
RESPONSE_FILE="$RESULT_DIR/permission-response.json"
TIMEOUT="${CC_PERM_TIMEOUT:-120}"
POLL_INTERVAL="${CC_PERM_POLL_INTERVAL:-2}"
GATEWAY="${OPENCLAW_GATEWAY:-http://127.0.0.1:18789}"
TOKEN="${OPENCLAW_TOKEN:-}"

mkdir -p "$RESULT_DIR"

# ── 读取 Hook 输入（stdin JSON）──────────────────────
INPUT=$(cat)

# ── 解析关键字段 ─────────────────────────────────────
TOOL_NAME=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('tool_name', 'unknown'))
" 2>/dev/null || echo "unknown")

TOOL_INPUT_SUMMARY=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ti = data.get('tool_input', {})
# 构建人类可读的摘要
if 'command' in ti:
    print(f\"命令: {ti['command']}\")
elif 'file_path' in ti:
    content_preview = ti.get('content', '')[:200]
    print(f\"文件: {ti['file_path']}\")
    if content_preview:
        print(f\"内容预览: {content_preview}...\")
else:
    print(json.dumps(ti, ensure_ascii=False)[:300])
" 2>/dev/null || echo "(无法解析)")

echo "[permission-proxy] 收到权限请求: $TOOL_NAME" >&2
echo "[permission-proxy] $TOOL_INPUT_SUMMARY" >&2

# ── 清理旧的响应文件 ─────────────────────────────────
rm -f "$RESPONSE_FILE"

# ── 写入 pending-permission.json ─────────────────────
echo "$INPUT" | python3 -c "
import json, sys
from datetime import datetime, timezone

data = json.load(sys.stdin)
pending = {
    'hook_event': 'PermissionRequest',
    'timestamp': datetime.now(timezone.utc).isoformat(),
    'tool_name': data.get('tool_name', 'unknown'),
    'tool_input': data.get('tool_input', {}),
    'permission_suggestions': data.get('permission_suggestions', []),
    'session_id': data.get('session_id', ''),
    'cwd': data.get('cwd', ''),
    'permission_mode': data.get('permission_mode', ''),
    'status': 'waiting_for_user',
    'timeout_seconds': $TIMEOUT,
    'response_file': '$RESPONSE_FILE'
}
with open('$PENDING_FILE', 'w') as f:
    json.dump(pending, f, indent=2, ensure_ascii=False)
print('[permission-proxy] pending-permission.json 已写入', file=sys.stderr)
"

# ── 发送 Wake Event（通知 OpenClaw 来处理）───────────
WAKE_TEXT="⚠️ Claude Code 请求权限确认: [$TOOL_NAME] $TOOL_INPUT_SUMMARY — 请读取 $PENDING_FILE 并使用 cc-respond.sh 回复"

if [ -n "$TOKEN" ]; then
    curl -s -X POST "${GATEWAY}/api/cron/wake" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"text\": $(echo "$WAKE_TEXT" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))"), \"mode\": \"now\"}" \
        >/dev/null 2>&1 || true
    echo "[permission-proxy] wake event 已发送" >&2
elif command -v openclaw &>/dev/null; then
    openclaw system event --text "$WAKE_TEXT" --mode now 2>/dev/null || true
    echo "[permission-proxy] wake event 已通过 CLI 发送" >&2
else
    echo "[permission-proxy] 警告: 无法发送 wake event，等待用户手动响应" >&2
fi

# ── 轮询等待 permission-response.json ────────────────
ELAPSED=0
echo "[permission-proxy] 等待用户响应（超时: ${TIMEOUT}s）..." >&2

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    if [ -f "$RESPONSE_FILE" ]; then
        echo "[permission-proxy] 收到用户响应" >&2

        # 读取响应并构建 Hook 输出
        RESPONSE=$(python3 -c "
import json, sys

with open('$RESPONSE_FILE') as f:
    resp = json.load(f)

behavior = resp.get('behavior', 'deny')
updated_input = resp.get('updated_input', None)
message = resp.get('message', '')

output = {
    'hookSpecificOutput': {
        'hookEventName': 'PermissionRequest',
        'decision': {
            'behavior': behavior
        }
    }
}

if updated_input and behavior == 'allow':
    output['hookSpecificOutput']['decision']['updatedInput'] = updated_input

if message and behavior == 'deny':
    output['hookSpecificOutput']['decision']['message'] = message

print(json.dumps(output, ensure_ascii=False))
" 2>/dev/null)

        # 清理文件
        rm -f "$RESPONSE_FILE"

        # 更新 pending 状态
        python3 -c "
import json
with open('$PENDING_FILE') as f:
    p = json.load(f)
p['status'] = 'responded'
with open('$PENDING_FILE', 'w') as f:
    json.dump(p, f, indent=2, ensure_ascii=False)
" 2>/dev/null || true

        echo "[permission-proxy] 决策: $(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['hookSpecificOutput']['decision']['behavior'])" 2>/dev/null || echo "unknown")" >&2

        # 输出 JSON 到 stdout（Claude Code 读取）
        echo "$RESPONSE"
        exit 0
    fi

    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# ── 超时：默认拒绝（安全）────────────────────────────
echo "[permission-proxy] 超时（${TIMEOUT}s），默认拒绝" >&2

# 更新 pending 状态
python3 -c "
import json
with open('$PENDING_FILE') as f:
    p = json.load(f)
p['status'] = 'timeout_denied'
with open('$PENDING_FILE', 'w') as f:
    json.dump(p, f, indent=2, ensure_ascii=False)
" 2>/dev/null || true

# 返回拒绝决策
cat << 'EOF'
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"权限请求超时，用户未响应，默认拒绝。"}}}
EOF
exit 0
