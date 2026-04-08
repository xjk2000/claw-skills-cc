#!/usr/bin/env bash
# cc-session.sh — Claude Code 会话管理（创建/列出/恢复/关闭）
# 用法: cc-session.sh <action> [options]
#
# Actions:
#   create  <project-path> [session-name]  — 创建新会话
#   list                                    — 列出活跃会话
#   resume  <session-name> <prompt>         — 恢复会话并发送 prompt
#   close   <session-name>                  — 关闭会话
#   status  <session-name>                  — 查看会话状态
#
# 环境变量:
#   ACPX_PLUGIN_ROOT — acpx 插件根目录
#
# 作者: XuJiaKai

set -euo pipefail

ACTION="${1:?用法: cc-session.sh <create|list|resume|close|status> [options]}"
shift

# 解析 ACPX 命令路径
resolve_acpx() {
    local cmd="${ACPX_PLUGIN_ROOT:-$HOME/.openclaw/extensions/acpx}/node_modules/.bin/acpx"
    if [ -x "$cmd" ]; then
        echo "$cmd"
        return
    fi
    if command -v acpx &>/dev/null; then
        echo "acpx"
        return
    fi
    echo "ERROR: acpx 未找到" >&2
    return 1
}

case "$ACTION" in
    create)
        PROJECT_PATH="${1:?用法: cc-session.sh create <project-path> [session-name]}"
        SESSION_NAME="${2:-cc-$(basename "$PROJECT_PATH")-$(date +%Y%m%d-%H%M%S)}"
        
        if [ ! -d "$PROJECT_PATH" ]; then
            echo "ERROR: 项目路径不存在: $PROJECT_PATH" >&2
            exit 1
        fi

        ACPX_CMD=$(resolve_acpx)
        
        echo "创建会话: $SESSION_NAME" >&2
        echo "项目路径: $PROJECT_PATH" >&2
        
        "$ACPX_CMD" claude sessions new --name "$SESSION_NAME" 2>&1 || true
        
        echo "$SESSION_NAME"
        ;;

    list)
        ACPX_CMD=$(resolve_acpx)
        "$ACPX_CMD" claude sessions list 2>&1
        ;;

    resume)
        SESSION_NAME="${1:?用法: cc-session.sh resume <session-name> <prompt>}"
        PROMPT="${2:?缺少 prompt}"
        PROJECT_PATH="${3:-.}"
        
        ACPX_CMD=$(resolve_acpx)
        
        echo "恢复会话: $SESSION_NAME" >&2
        echo "Prompt: ${PROMPT:0:100}..." >&2
        
        "$ACPX_CMD" claude \
            -s "$SESSION_NAME" \
            --cwd "$PROJECT_PATH" \
            --format quiet \
            "$PROMPT"
        ;;

    close)
        SESSION_NAME="${1:?用法: cc-session.sh close <session-name>}"
        
        ACPX_CMD=$(resolve_acpx)
        
        echo "关闭会话: $SESSION_NAME" >&2
        "$ACPX_CMD" claude sessions close "$SESSION_NAME" 2>&1
        ;;

    status)
        SESSION_NAME="${1:?用法: cc-session.sh status <session-name>}"
        
        ACPX_CMD=$(resolve_acpx)
        "$ACPX_CMD" claude sessions show "$SESSION_NAME" 2>&1
        ;;

    *)
        echo "ERROR: 未知操作: $ACTION" >&2
        echo "支持: create, list, resume, close, status" >&2
        exit 1
        ;;
esac
