#!/usr/bin/env bash
# notify-agi.sh — Claude Code Stop/SessionEnd Hook
# 任务完成后自动：
#   1. 写入 latest.json（数据通道 — 快递柜）
#   2. 发送 wake event 到 OpenClaw Gateway（信号通道 — 门铃）
#
# 由 Claude Code 的 Stop / SessionEnd hook 自动触发
# 使用 .hook-lock 防重复（30 秒内去重）
#
# 环境变量：
#   CC_RESULT_DIR    — 结果文件目录，默认 ~/.openclaw/data/claude-code-results
#   CC_TASK_META     — task-meta.json 路径，默认 $CC_RESULT_DIR/task-meta.json
#   OPENCLAW_GATEWAY — Gateway 地址，默认 http://127.0.0.1:18789
#   OPENCLAW_TOKEN   — Gateway 认证 token
#
# 作者: XuJiaKai

set -euo pipefail

# ── 配置 ──────────────────────────────────────────────
RESULT_DIR="${CC_RESULT_DIR:-$HOME/.openclaw/data/claude-code-results}"
TASK_META="${CC_TASK_META:-$RESULT_DIR/task-meta.json}"
LOCK_FILE="$RESULT_DIR/.hook-lock"
GATEWAY="${OPENCLAW_GATEWAY:-http://127.0.0.1:18789}"
TOKEN="${OPENCLAW_TOKEN:-}"
LOCK_TTL=30  # 秒，防重复窗口

mkdir -p "$RESULT_DIR"

# ── 防重复（30 秒内只处理一次）────────────────────────
if [ -f "$LOCK_FILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -lt "$LOCK_TTL" ]; then
        echo "[notify-agi] 跳过：${LOCK_AGE}s 内已触发过（去重窗口 ${LOCK_TTL}s）" >&2
        exit 0
    fi
fi
touch "$LOCK_FILE"

# ── 收集任务信息 ──────────────────────────────────────
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
SESSION_ID="${CLAUDE_SESSION_ID:-unknown-$(date +%s)}"
CWD="${CLAUDE_CWD:-$(pwd)}"
EVENT="${CLAUDE_EVENT:-Stop}"

# 读取 task-meta.json（如果存在）
TASK_NAME="unknown"
if [ -f "$TASK_META" ]; then
    TASK_NAME=$(python3 -c "
import json, sys
try:
    with open('$TASK_META') as f:
        print(json.load(f).get('task_name', 'unknown'))
except:
    print('unknown')
" 2>/dev/null || echo "unknown")
fi

# 收集 Claude Code 输出
# 优先从 task-output.txt 读取，否则从 stdin/环境变量
OUTPUT=""
TASK_OUTPUT_FILE="$RESULT_DIR/task-output.txt"
if [ -f "$TASK_OUTPUT_FILE" ]; then
    OUTPUT=$(head -c 50000 "$TASK_OUTPUT_FILE")
elif [ -n "${CLAUDE_OUTPUT:-}" ]; then
    OUTPUT="$CLAUDE_OUTPUT"
else
    # 尝试从 stdin 读取（非阻塞）
    if [ -t 0 ]; then
        OUTPUT="(no output captured)"
    else
        OUTPUT=$(timeout 2 cat 2>/dev/null || echo "(no output captured)")
    fi
fi

# ── 写入 latest.json（数据通道）─────────────────────
python3 -c "
import json, sys

result = {
    'session_id': '$SESSION_ID',
    'timestamp': '$TIMESTAMP',
    'task_name': '$TASK_NAME',
    'cwd': '$CWD',
    'event': '$EVENT',
    'output': sys.stdin.read(),
    'status': 'done'
}

with open('$RESULT_DIR/latest.json', 'w') as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

print('[notify-agi] latest.json 已写入: $RESULT_DIR/latest.json', file=sys.stderr)
" <<< "$OUTPUT"

# ── 同时写入历史记录（按任务名归档）──────────────────
HISTORY_DIR="$RESULT_DIR/history"
mkdir -p "$HISTORY_DIR"
HISTORY_FILE="$HISTORY_DIR/${TASK_NAME}-$(date +%Y%m%d-%H%M%S).json"
cp "$RESULT_DIR/latest.json" "$HISTORY_FILE" 2>/dev/null || true

# ── 发送 Wake Event（信号通道）───────────────────────
WAKE_TEXT="Claude Code 任务完成: ${TASK_NAME}。读取 $RESULT_DIR/latest.json 获取结果。"

if [ -n "$TOKEN" ]; then
    curl -s -X POST "${GATEWAY}/api/cron/wake" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"text\": \"$WAKE_TEXT\", \"mode\": \"now\"}" \
        >/dev/null 2>&1 || true
    echo "[notify-agi] wake event 已发送" >&2
else
    # 无 token 时尝试 openclaw CLI
    if command -v openclaw &>/dev/null; then
        openclaw system event --text "$WAKE_TEXT" --mode now 2>/dev/null || true
        echo "[notify-agi] wake event 已通过 CLI 发送" >&2
    else
        echo "[notify-agi] 警告：无法发送 wake event（未设置 OPENCLAW_TOKEN 且 openclaw CLI 不可用）" >&2
        echo "[notify-agi] 结果已写入 latest.json，AGI 将在下次 heartbeat 时读取" >&2
    fi
fi

# ── 写入 pending-wake.json（备选通道）────────────────
# 即使 wake event 失败，AGI heartbeat 也能读取
python3 -c "
import json
wake = {
    'task_name': '$TASK_NAME',
    'timestamp': '$TIMESTAMP',
    'result_file': '$RESULT_DIR/latest.json',
    'message': '$WAKE_TEXT'
}
with open('$RESULT_DIR/pending-wake.json', 'w') as f:
    json.dump(wake, f, indent=2, ensure_ascii=False)
" 2>/dev/null || true

echo "[notify-agi] 完成。任务: $TASK_NAME, 结果: $RESULT_DIR/latest.json" >&2
