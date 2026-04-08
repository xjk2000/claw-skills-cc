#!/usr/bin/env bash
# cc-poll.sh — 轮询 Claude Code 执行输出，检测完成/阻塞状态
# 用法: cc-poll.sh <session-id> [interval] [max-idle]
#
# 参数:
#   session-id  — OpenClaw exec 返回的 sessionId
#   interval    — 轮询间隔(秒)，默认 5
#   max-idle    — 最大空闲时间(秒，无新输出)，默认 600
#
# 输出状态码:
#   0  — TASK_COMPLETE (任务完成)
#   1  — TASK_BLOCKED  (任务阻塞，需要介入)
#   2  — TASK_TIMEOUT  (超时无输出)
#   3  — TASK_FAILED   (进程异常退出)
#   4  — TASK_RUNNING  (仍在运行，手动中断)
#
# 输出格式 (stdout, 每行一个 JSON):
#   {"ts":"...","status":"running|complete|blocked|timeout|failed","detail":"...","offset":N}
#
# 作者: XuJiaKai

set -euo pipefail

SESSION_ID="${1:?用法: cc-poll.sh <session-id> [interval] [max-idle]}"
INTERVAL="${2:-5}"
MAX_IDLE="${3:-600}"

LAST_OFFSET=0
LAST_OUTPUT_TIME=$(date +%s)
ACCUMULATED=""

emit_status() {
    local status="$1"
    local detail="$2"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "{\"ts\":\"$ts\",\"status\":\"$status\",\"detail\":$(echo "$detail" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo "\"$detail\""),\"offset\":$LAST_OFFSET}"
}

# 主轮询循环
while true; do
    # 获取新输出（从上次偏移开始）
    NEW_OUTPUT=$(process action:log sessionId:"$SESSION_ID" offset:"$LAST_OFFSET" 2>/dev/null || echo "")

    if [ -n "$NEW_OUTPUT" ]; then
        NEW_LEN=${#NEW_OUTPUT}
        LAST_OFFSET=$((LAST_OFFSET + NEW_LEN))
        LAST_OUTPUT_TIME=$(date +%s)
        ACCUMULATED="${ACCUMULATED}${NEW_OUTPUT}"

        # 检测完成标记
        if echo "$NEW_OUTPUT" | grep -q "TASK_COMPLETE:"; then
            SUMMARY=$(echo "$NEW_OUTPUT" | grep -o "TASK_COMPLETE:.*" | head -1 | sed 's/TASK_COMPLETE: *//')
            emit_status "complete" "$SUMMARY"
            exit 0
        fi

        # 检测阻塞标记
        if echo "$NEW_OUTPUT" | grep -q "TASK_BLOCKED:"; then
            REASON=$(echo "$NEW_OUTPUT" | grep -o "TASK_BLOCKED:.*" | head -1 | sed 's/TASK_BLOCKED: *//')
            emit_status "blocked" "$REASON"
            exit 1
        fi

        # 检测常见错误模式
        if echo "$NEW_OUTPUT" | grep -qiE "(permission denied|EACCES|sudo required)"; then
            emit_status "blocked" "权限不足: 需要用户确认"
            exit 1
        fi

        # 发送进度状态
        LAST_LINE=$(echo "$NEW_OUTPUT" | tail -1 | head -c 200)
        emit_status "running" "$LAST_LINE"
    fi

    # 检查进程是否仍在运行
    POLL_RESULT=$(process action:poll sessionId:"$SESSION_ID" 2>/dev/null || echo "error")

    if echo "$POLL_RESULT" | grep -qi "done\|finished\|exited\|completed"; then
        # 进程已结束，检查最终输出
        FINAL_OUTPUT=$(process action:log sessionId:"$SESSION_ID" offset:"$LAST_OFFSET" 2>/dev/null || echo "")

        if echo "$ACCUMULATED$FINAL_OUTPUT" | grep -q "TASK_COMPLETE:"; then
            SUMMARY=$(echo "$ACCUMULATED$FINAL_OUTPUT" | grep -o "TASK_COMPLETE:.*" | tail -1 | sed 's/TASK_COMPLETE: *//')
            emit_status "complete" "$SUMMARY"
            exit 0
        fi

        if echo "$ACCUMULATED$FINAL_OUTPUT" | grep -q "TASK_BLOCKED:"; then
            REASON=$(echo "$ACCUMULATED$FINAL_OUTPUT" | grep -o "TASK_BLOCKED:.*" | tail -1 | sed 's/TASK_BLOCKED: *//')
            emit_status "blocked" "$REASON"
            exit 1
        fi

        # 进程结束但没有明确标记，视为完成
        emit_status "complete" "进程已退出（无明确完成标记，请检查输出）"
        exit 0
    fi

    if echo "$POLL_RESULT" | grep -qi "error\|not found"; then
        emit_status "failed" "进程异常: $POLL_RESULT"
        exit 3
    fi

    # 检查空闲超时
    NOW=$(date +%s)
    IDLE_TIME=$((NOW - LAST_OUTPUT_TIME))
    if [ "$IDLE_TIME" -ge "$MAX_IDLE" ]; then
        emit_status "timeout" "空闲超时 ${IDLE_TIME}s（上限 ${MAX_IDLE}s）"
        exit 2
    fi

    sleep "$INTERVAL"
done
