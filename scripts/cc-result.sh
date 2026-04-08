#!/usr/bin/env bash
# cc-result.sh — 读取 Claude Code 任务结果
#
# 用法:
#   cc-result.sh [action]
#
# Actions:
#   latest    — 读取最新结果 latest.json（默认）
#   status    — 检查当前任务状态（运行中/已完成）
#   history   — 列出历史结果
#   pending   — 检查 pending-wake.json（备选唤醒通道）
#   clean     — 清理 pending-wake.json（AGI 读取后调用）
#   output    — 读取原始输出文件 task-output.txt
#
# 环境变量:
#   CC_RESULT_DIR — 结果文件目录，默认 ~/.openclaw/data/claude-code-results
#
# 作者: XuJiaKai

set -euo pipefail

ACTION="${1:-latest}"
RESULT_DIR="${CC_RESULT_DIR:-$HOME/.openclaw/data/claude-code-results}"

case "$ACTION" in
    latest)
        LATEST="$RESULT_DIR/latest.json"
        if [ ! -f "$LATEST" ]; then
            echo '{"status": "no_result", "message": "没有找到结果文件"}' 
            exit 0
        fi
        cat "$LATEST"
        ;;

    status)
        META="$RESULT_DIR/task-meta.json"
        if [ ! -f "$META" ]; then
            echo '{"status": "no_task", "message": "没有正在执行的任务"}'
            exit 0
        fi

        PID=$(python3 -c "
import json
with open('$META') as f:
    meta = json.load(f)
print(meta.get('pid', ''))
" 2>/dev/null || echo "")

        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            # 进程仍在运行
            python3 -c "
import json, os
with open('$META') as f:
    meta = json.load(f)

output_file = '$RESULT_DIR/task-output.txt'
output_size = os.path.getsize(output_file) if os.path.exists(output_file) else 0

# 读取最后几行输出作为预览
tail = ''
if os.path.exists(output_file):
    with open(output_file, 'rb') as f:
        f.seek(max(0, output_size - 500))
        tail = f.read().decode('utf-8', errors='replace').strip()[-300:]

result = {
    'status': 'running',
    'task_name': meta.get('task_name', 'unknown'),
    'pid': meta.get('pid'),
    'workdir': meta.get('workdir', ''),
    'dispatched_at': meta.get('dispatched_at', ''),
    'output_size': output_size,
    'output_tail': tail
}
print(json.dumps(result, indent=2, ensure_ascii=False))
"
        else
            # 进程已结束，检查是否有结果
            if [ -f "$RESULT_DIR/latest.json" ]; then
                echo '{"status": "completed", "message": "任务已完成，使用 latest 查看结果"}'
            else
                echo '{"status": "exited", "message": "进程已退出但未生成结果文件"}'
            fi
        fi
        ;;

    history)
        HISTORY_DIR="$RESULT_DIR/history"
        if [ ! -d "$HISTORY_DIR" ] || [ -z "$(ls -A "$HISTORY_DIR" 2>/dev/null)" ]; then
            echo '{"status": "no_history", "message": "没有历史记录"}'
            exit 0
        fi
        echo "["
        FIRST=true
        for f in "$HISTORY_DIR"/*.json; do
            if [ "$FIRST" = true ]; then
                FIRST=false
            else
                echo ","
            fi
            # 输出摘要（不含完整 output）
            python3 -c "
import json
with open('$f') as fh:
    data = json.load(fh)
summary = {k: v for k, v in data.items() if k != 'output'}
summary['output_length'] = len(data.get('output', ''))
summary['file'] = '$f'
print(json.dumps(summary, indent=2, ensure_ascii=False))
" 2>/dev/null || true
        done
        echo "]"
        ;;

    pending)
        PENDING="$RESULT_DIR/pending-wake.json"
        if [ ! -f "$PENDING" ]; then
            echo '{"status": "no_pending", "message": "没有待处理的唤醒通知"}'
            exit 0
        fi
        cat "$PENDING"
        ;;

    clean)
        # AGI 读取结果后清理 pending-wake
        rm -f "$RESULT_DIR/pending-wake.json"
        rm -f "$RESULT_DIR/.hook-lock"
        echo '{"status": "cleaned", "message": "已清理 pending-wake 和 hook-lock"}'
        ;;

    output)
        OUTPUT_FILE="$RESULT_DIR/task-output.txt"
        if [ ! -f "$OUTPUT_FILE" ]; then
            echo "(无输出文件)"
            exit 0
        fi
        # 默认输出最后 200 行
        LINES="${2:-200}"
        tail -n "$LINES" "$OUTPUT_FILE"
        ;;

    *)
        echo "ERROR: 未知操作: $ACTION" >&2
        echo "支持: latest, status, history, pending, clean, output" >&2
        exit 1
        ;;
esac
