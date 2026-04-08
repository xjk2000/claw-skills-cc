#!/usr/bin/env bash
# cc-invoke.sh — 调用 Claude Code CLI 执行任务
# 用法: cc-invoke.sh <project-path> <task-description> [session-name] [mode]
# 
# 参数:
#   project-path      — 目标项目路径
#   task-description  — 任务描述
#   session-name      — 可选，会话名称（用于 acpx 持续会话模式）
#   mode              — 可选，执行模式: direct(默认) | acpx | acpx-oneshot
#
# 环境变量:
#   CC_TIMEOUT        — 超时时间(秒)，默认 600
#   CC_OUTPUT_FORMAT  — 输出格式: stream-json(默认) | text
#   ACPX_PLUGIN_ROOT  — acpx 插件根目录
#
# 作者: XuJiaKai

set -euo pipefail

PROJECT_PATH="${1:?用法: cc-invoke.sh <project-path> <task-description> [session-name] [mode]}"
TASK_DESC="${2:?缺少任务描述}"
SESSION_NAME="${3:-}"
MODE="${4:-direct}"

TIMEOUT="${CC_TIMEOUT:-600}"
OUTPUT_FORMAT="${CC_OUTPUT_FORMAT:-stream-json}"

# 任务完成标记注入
TASK_SUFFIX='

完成后请输出: TASK_COMPLETE: <简要总结>
如果遇到无法自行解决的问题，请输出: TASK_BLOCKED: <原因描述>'

FULL_TASK="${TASK_DESC}${TASK_SUFFIX}"

# 验证项目路径
if [ ! -d "$PROJECT_PATH" ]; then
    echo "ERROR: 项目路径不存在: $PROJECT_PATH" >&2
    exit 1
fi

case "$MODE" in
    direct)
        # 模式 1: 直接调用 claude CLI
        if ! command -v claude &>/dev/null; then
            echo "ERROR: claude CLI 未安装。请运行: npm install -g @anthropic-ai/claude-code" >&2
            exit 1
        fi

        echo "=== Claude Code Direct 模式 ===" >&2
        echo "项目: $PROJECT_PATH" >&2
        echo "任务: ${TASK_DESC:0:100}..." >&2
        echo "超时: ${TIMEOUT}s" >&2
        echo "================================" >&2

        cd "$PROJECT_PATH"
        timeout "$TIMEOUT" claude \
            --print \
            --permission-mode bypassPermissions \
            --output-format "$OUTPUT_FORMAT" \
            "$FULL_TASK"
        ;;

    acpx)
        # 模式 2: ACPX 持续会话模式
        ACPX_CMD="${ACPX_PLUGIN_ROOT:-$HOME/.openclaw/extensions/acpx}/node_modules/.bin/acpx"
        
        if [ ! -x "$ACPX_CMD" ]; then
            # 回退到全局 acpx
            if command -v acpx &>/dev/null; then
                ACPX_CMD="acpx"
            else
                echo "ERROR: acpx 未找到。请确认 ACPX_PLUGIN_ROOT 或全局安装 acpx" >&2
                exit 1
            fi
        fi

        if [ -z "$SESSION_NAME" ]; then
            SESSION_NAME="cc-$(basename "$PROJECT_PATH")-$(date +%s)"
        fi

        echo "=== Claude Code ACPX 会话模式 ===" >&2
        echo "项目: $PROJECT_PATH" >&2
        echo "会话: $SESSION_NAME" >&2
        echo "任务: ${TASK_DESC:0:100}..." >&2
        echo "==================================" >&2

        timeout "$TIMEOUT" "$ACPX_CMD" claude \
            -s "$SESSION_NAME" \
            --cwd "$PROJECT_PATH" \
            --format quiet \
            "$FULL_TASK"
        ;;

    acpx-oneshot)
        # 模式 3: ACPX 一次性执行
        ACPX_CMD="${ACPX_PLUGIN_ROOT:-$HOME/.openclaw/extensions/acpx}/node_modules/.bin/acpx"
        
        if [ ! -x "$ACPX_CMD" ]; then
            if command -v acpx &>/dev/null; then
                ACPX_CMD="acpx"
            else
                echo "ERROR: acpx 未找到" >&2
                exit 1
            fi
        fi

        echo "=== Claude Code ACPX 一次性模式 ===" >&2
        echo "项目: $PROJECT_PATH" >&2
        echo "任务: ${TASK_DESC:0:100}..." >&2
        echo "====================================" >&2

        timeout "$TIMEOUT" "$ACPX_CMD" claude exec \
            --cwd "$PROJECT_PATH" \
            --format quiet \
            "$FULL_TASK"
        ;;

    *)
        echo "ERROR: 未知模式: $MODE (支持: direct, acpx, acpx-oneshot)" >&2
        exit 1
        ;;
esac

EXIT_CODE=$?
if [ $EXIT_CODE -eq 124 ]; then
    echo "TASK_TIMEOUT: 任务超时 (${TIMEOUT}s)" >&2
fi
exit $EXIT_CODE
