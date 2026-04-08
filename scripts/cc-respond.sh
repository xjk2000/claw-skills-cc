#!/usr/bin/env bash
# cc-respond.sh — 响应 Claude Code 权限请求
#
# OpenClaw 读取 pending-permission.json 后，调用此脚本写入决策。
# permission-proxy.sh 会轮询读取 permission-response.json 并返回给 Claude Code。
#
# 用法:
#   cc-respond.sh allow                    — 允许
#   cc-respond.sh deny [reason]            — 拒绝（可附原因）
#   cc-respond.sh allow --modify 'cmd'     — 允许但修改命令
#   cc-respond.sh pending                  — 查看当前待处理的权限请求
#   cc-respond.sh history                  — 查看权限请求历史
#
# 环境变量:
#   CC_RESULT_DIR — 结果目录，默认 ~/.openclaw/data/claude-code-results
#
# 作者: XuJiaKai

set -euo pipefail

ACTION="${1:?用法: cc-respond.sh <allow|deny|pending|history> [options]}"
shift || true

RESULT_DIR="${CC_RESULT_DIR:-$HOME/.openclaw/data/claude-code-results}"
PENDING_FILE="$RESULT_DIR/pending-permission.json"
RESPONSE_FILE="$RESULT_DIR/permission-response.json"
PERM_HISTORY_DIR="$RESULT_DIR/permission-history"

mkdir -p "$RESULT_DIR"
mkdir -p "$PERM_HISTORY_DIR"

case "$ACTION" in
    allow)
        MODIFIED_CMD=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --modify) MODIFIED_CMD="$2"; shift 2 ;;
                *) shift ;;
            esac
        done

        if [ -n "$MODIFIED_CMD" ]; then
            # 允许但修改命令
            python3 -c "
import json
response = {
    'behavior': 'allow',
    'updated_input': {'command': '$MODIFIED_CMD'},
    'message': ''
}
with open('$RESPONSE_FILE', 'w') as f:
    json.dump(response, f, indent=2, ensure_ascii=False)
print('已允许（修改命令为: $MODIFIED_CMD）')
"
        else
            # 直接允许
            python3 -c "
import json
response = {
    'behavior': 'allow',
    'updated_input': None,
    'message': ''
}
with open('$RESPONSE_FILE', 'w') as f:
    json.dump(response, f, indent=2, ensure_ascii=False)
print('已允许')
"
        fi

        # 归档
        if [ -f "$PENDING_FILE" ]; then
            cp "$PENDING_FILE" "$PERM_HISTORY_DIR/$(date +%Y%m%d-%H%M%S)-allow.json" 2>/dev/null || true
        fi
        ;;

    deny)
        REASON="${1:-用户拒绝了此操作}"

        python3 -c "
import json
response = {
    'behavior': 'deny',
    'updated_input': None,
    'message': '''$REASON'''
}
with open('$RESPONSE_FILE', 'w') as f:
    json.dump(response, f, indent=2, ensure_ascii=False)
print('已拒绝: $REASON')
"
        # 归档
        if [ -f "$PENDING_FILE" ]; then
            cp "$PENDING_FILE" "$PERM_HISTORY_DIR/$(date +%Y%m%d-%H%M%S)-deny.json" 2>/dev/null || true
        fi
        ;;

    pending)
        if [ ! -f "$PENDING_FILE" ]; then
            echo '{"status": "no_pending", "message": "没有待处理的权限请求"}'
            exit 0
        fi
        cat "$PENDING_FILE"
        ;;

    history)
        if [ ! -d "$PERM_HISTORY_DIR" ] || [ -z "$(ls -A "$PERM_HISTORY_DIR" 2>/dev/null)" ]; then
            echo '{"status": "no_history", "message": "没有权限请求历史"}'
            exit 0
        fi
        echo "["
        FIRST=true
        for f in "$PERM_HISTORY_DIR"/*.json; do
            [ "$FIRST" = true ] && FIRST=false || echo ","
            python3 -c "
import json
with open('$f') as fh:
    data = json.load(fh)
summary = {
    'file': '$(basename "$f")',
    'tool_name': data.get('tool_name', ''),
    'status': data.get('status', ''),
    'timestamp': data.get('timestamp', '')
}
print(json.dumps(summary, indent=2, ensure_ascii=False))
" 2>/dev/null || true
        done
        echo "]"
        ;;

    *)
        echo "ERROR: 未知操作: $ACTION" >&2
        echo "用法: cc-respond.sh <allow|deny|pending|history>" >&2
        exit 1
        ;;
esac
