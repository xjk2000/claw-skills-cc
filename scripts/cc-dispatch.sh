#!/usr/bin/env bash
# cc-dispatch.sh — 派发任务到 Claude Code（发射后不管）
#
# 用法:
#   cc-dispatch.sh -p "任务描述" -n "任务名" [options]
#
# 参数:
#   -p, --prompt           任务描述（必需）
#   -n, --name             任务名称（必需）
#   -w, --workdir          工作目录，默认当前目录
#   --permission-mode      权限模式，默认 bypassPermissions
#   --proxied              启用权限代理模式（permission-mode 设为 default，
#                          权限请求透传给 OpenClaw 用户确认）
#   --agent-teams          启用 Agent Teams 协作模式
#   --teammate-mode        Agent Teams 模式: auto(默认) | manual
#   --allowed-tools        允许的工具列表（逗号分隔）
#   --model                指定模型
#   --max-turns            最大对话轮数
#
# 工作流程:
#   1. 写入 task-meta.json（任务元数据）
#   2. 启动 Claude Code（nohup 后台）
#   3. 立即返回，不等待完成
#   4. Claude Code 完成后 Stop Hook 自动回调
#
# 环境变量:
#   CC_RESULT_DIR  — 结果文件目录，默认 ~/.openclaw/data/claude-code-results
#
# 作者: XuJiaKai

set -euo pipefail

# ── 参数解析 ──────────────────────────────────────────
PROMPT=""
TASK_NAME=""
WORKDIR="$(pwd)"
PERMISSION_MODE="bypassPermissions"
PROXIED=false
AGENT_TEAMS=false
TEAMMATE_MODE="auto"
ALLOWED_TOOLS=""
MODEL=""
MAX_TURNS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prompt)        PROMPT="$2"; shift 2 ;;
        -n|--name)          TASK_NAME="$2"; shift 2 ;;
        -w|--workdir)       WORKDIR="$2"; shift 2 ;;
        --permission-mode)  PERMISSION_MODE="$2"; shift 2 ;;
        --proxied)          PROXIED=true; shift ;;
        --agent-teams)      AGENT_TEAMS=true; shift ;;
        --teammate-mode)    TEAMMATE_MODE="$2"; shift 2 ;;
        --allowed-tools)    ALLOWED_TOOLS="$2"; shift 2 ;;
        --model)            MODEL="$2"; shift 2 ;;
        --max-turns)        MAX_TURNS="$2"; shift 2 ;;
        *)
            echo "ERROR: 未知参数: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$PROMPT" ]; then
    echo "ERROR: 缺少 -p/--prompt 参数" >&2
    exit 1
fi
if [ -z "$TASK_NAME" ]; then
    TASK_NAME="task-$(date +%s)"
fi

# ── 验证 ──────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
    echo "ERROR: claude CLI 未安装。请运行: npm install -g @anthropic-ai/claude-code" >&2
    exit 1
fi

if [ ! -d "$WORKDIR" ]; then
    echo "ERROR: 工作目录不存在: $WORKDIR" >&2
    exit 1
fi

# ── 结果目录 ──────────────────────────────────────────
RESULT_DIR="${CC_RESULT_DIR:-$HOME/.openclaw/data/claude-code-results}"
mkdir -p "$RESULT_DIR"

# ── 写入 task-meta.json ──────────────────────────────
python3 -c "
import json, os
meta = {
    'task_name': '$TASK_NAME',
    'prompt': '''$PROMPT''',
    'workdir': '$WORKDIR',
    'permission_mode': '$PERMISSION_MODE',
    'agent_teams': $( [ "$AGENT_TEAMS" = true ] && echo "True" || echo "False" ),
    'teammate_mode': '$TEAMMATE_MODE',
    'dispatched_at': '$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")',
    'pid': None
}
with open('$RESULT_DIR/task-meta.json', 'w') as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
"

# 权限代理模式：覆盖 permission-mode 为 default
if [ "$PROXIED" = true ]; then
    PERMISSION_MODE="default"
    echo "[dispatch] 权限代理模式已启用 — 权限请求将透传给 OpenClaw 用户" >&2
fi

echo "=== Claude Code Dispatch ===" >&2
echo "任务: $TASK_NAME" >&2
echo "目录: $WORKDIR" >&2
echo "权限: $PERMISSION_MODE$( [ "$PROXIED" = true ] && echo " (proxied → 用户确认)" || echo "" )" >&2
echo "模式: $( [ "$AGENT_TEAMS" = true ] && echo "Agent Teams ($TEAMMATE_MODE)" || echo "单 Agent" )" >&2
echo "============================" >&2

# ── 构建 Claude Code 命令 ─────────────────────────────
CMD="claude"
CMD="$CMD --print"
CMD="$CMD --permission-mode $PERMISSION_MODE"
CMD="$CMD --output-format text"

if [ "$AGENT_TEAMS" = true ]; then
    CMD="$CMD --agent-teams"
    CMD="$CMD --teammate-mode $TEAMMATE_MODE"
fi

if [ -n "$ALLOWED_TOOLS" ]; then
    CMD="$CMD --allowed-tools $ALLOWED_TOOLS"
fi

if [ -n "$MODEL" ]; then
    CMD="$CMD --model $MODEL"
fi

if [ -n "$MAX_TURNS" ]; then
    CMD="$CMD --max-turns $MAX_TURNS"
fi

# ── 输出文件 ──────────────────────────────────────────
OUTPUT_FILE="$RESULT_DIR/task-output.txt"

# ── 启动 Claude Code（后台，不等待）─────────────────
# 使用 nohup 确保即使调用方退出，Claude Code 也继续运行
# 输出重定向到 task-output.txt 供 Hook 读取
nohup bash -c "
    cd '$WORKDIR'
    export CC_RESULT_DIR='$RESULT_DIR'
    export CC_TASK_META='$RESULT_DIR/task-meta.json'
    $CMD '$PROMPT' > '$OUTPUT_FILE' 2>&1
    EXIT_CODE=\$?
    echo \"\" >> '$OUTPUT_FILE'
    echo \"[exit_code: \$EXIT_CODE]\" >> '$OUTPUT_FILE'
" > /dev/null 2>&1 &

BG_PID=$!

# 更新 task-meta.json 写入 PID
python3 -c "
import json
with open('$RESULT_DIR/task-meta.json') as f:
    meta = json.load(f)
meta['pid'] = $BG_PID
with open('$RESULT_DIR/task-meta.json', 'w') as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
"

echo "[dispatch] 任务已派发，PID: $BG_PID" >&2
echo "[dispatch] 输出文件: $OUTPUT_FILE" >&2
echo "[dispatch] 结果将写入: $RESULT_DIR/latest.json" >&2
echo "[dispatch] Claude Code 完成后 Hook 将自动通知 OpenClaw" >&2

# 输出 JSON 到 stdout，方便调用方解析
python3 -c "
import json
print(json.dumps({
    'task_name': '$TASK_NAME',
    'pid': $BG_PID,
    'workdir': '$WORKDIR',
    'output_file': '$OUTPUT_FILE',
    'result_dir': '$RESULT_DIR',
    'status': 'dispatched',
    'proxied': $( [ "$PROXIED" = true ] && echo "True" || echo "False" ),
    'permission_mode': '$PERMISSION_MODE'
}, indent=2))
"
