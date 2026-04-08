#!/usr/bin/env bash
# install.sh — claw-skill-cc 一键安装
# 用法: bash install.sh          # 安装
#       bash install.sh --uninstall  # 卸载
# 作者: XuJiaKai
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_NAME="claude-code-orchestrator"
SKILL_DIR="$HOME/.openclaw/skills/$SKILL_NAME"
RESULT_DIR="$HOME/.openclaw/data/claude-code-results"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
HOOK_NOTIFY="$SKILL_DIR/hooks/notify-agi.sh"
HOOK_PERMISSION="$SKILL_DIR/hooks/permission-proxy.sh"
HOOK_NOTIFICATION="$SKILL_DIR/hooks/notification-proxy.sh"

# ── 卸载 ──
if [[ "${1:-}" == "--uninstall" ]]; then
    step "卸载 claw-skill-cc"
    [ -e "$SKILL_DIR" ] && rm -rf "$SKILL_DIR" && ok "已移除: $SKILL_DIR"
    if [ -f "$CLAUDE_SETTINGS" ]; then
        python3 -c "
import json
with open('$CLAUDE_SETTINGS') as f: s=json.load(f)
h=s.get('hooks',{})
for e in ['Stop','SessionEnd','PermissionRequest','Notification']:
    if e in h:
        h[e]=[g for g in h[e] if not any(
            any(kw in x.get('command','') for kw in ['notify-agi.sh','permission-proxy.sh','notification-proxy.sh'])
            for x in g.get('hooks',[])
        )]
        if not h[e]: del h[e]
if not h: s.pop('hooks',None)
with open('$CLAUDE_SETTINGS','w') as f: json.dump(s,f,indent=2,ensure_ascii=False)
" 2>/dev/null && ok "已从 ~/.claude/settings.json 移除 Hook"
    fi
    ok "卸载完成！结果目录保留: $RESULT_DIR"
    exit 0
fi

# ══════════════════════════════════════════════════════
step "前置检查"
command -v python3 &>/dev/null && ok "python3 ✓" || { err "需要 python3"; exit 1; }
if command -v claude &>/dev/null; then
    ok "claude CLI ✓"
else
    warn "claude CLI 未安装 → npm install -g @anthropic-ai/claude-code"
fi
[ -d "$HOME/.openclaw" ] && ok "~/.openclaw ✓" || warn "~/.openclaw 不存在，将创建"

# ══════════════════════════════════════════════════════
step "第一部分：安装到 OpenClaw → $SKILL_DIR"
# ══════════════════════════════════════════════════════

if [ -e "$SKILL_DIR" ]; then
    if [ -L "$SKILL_DIR" ]; then rm "$SKILL_DIR"
    else mv "$SKILL_DIR" "$SKILL_DIR.bak.$(date +%s)"; warn "旧安装已备份"; fi
fi

mkdir -p "$SKILL_DIR"/{hooks,scripts,references}
mkdir -p "$RESULT_DIR"

cp "$SCRIPT_DIR/SKILL.md"                    "$SKILL_DIR/"
cp "$SCRIPT_DIR/README.md"                   "$SKILL_DIR/"
cp "$SCRIPT_DIR/hooks/notify-agi.sh"           "$SKILL_DIR/hooks/"
cp "$SCRIPT_DIR/hooks/permission-proxy.sh"     "$SKILL_DIR/hooks/"
cp "$SCRIPT_DIR/hooks/notification-proxy.sh"   "$SKILL_DIR/hooks/"
cp "$SCRIPT_DIR/hooks/claude-settings.json"    "$SKILL_DIR/hooks/"
cp "$SCRIPT_DIR/scripts/cc-dispatch.sh"        "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/cc-dispatch.py"        "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/cc-result.sh"          "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/cc-respond.sh"         "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/cc-session.sh"         "$SKILL_DIR/scripts/"
cp "$SCRIPT_DIR/references/task-strategy.md"   "$SKILL_DIR/references/"

chmod +x "$SKILL_DIR/hooks/"*.sh "$SKILL_DIR/scripts/"*.sh "$SKILL_DIR/scripts/"*.py

ok "Skill 文件已安装"
info "结果目录: $RESULT_DIR"
echo "  ├── SKILL.md                    → 技能定义"
echo "  ├── hooks/notify-agi.sh         → Stop/SessionEnd 回调"
echo "  ├── hooks/permission-proxy.sh   → 权限代理（透传给用户）"
echo "  ├── hooks/notification-proxy.sh → 通知转发"
echo "  ├── scripts/cc-dispatch.*       → 任务派发"
echo "  ├── scripts/cc-respond.sh       → 权限响应"
echo "  └── scripts/cc-result.sh        → 结果查询"

# ══════════════════════════════════════════════════════
step "第二部分：注册 Claude Code Hook → $CLAUDE_SETTINGS"
# ══════════════════════════════════════════════════════

mkdir -p "$HOME/.claude"

python3 << PYEOF
import json, os, shutil, sys
from datetime import datetime

path = "$CLAUDE_SETTINGS"

# Hook 定义: (事件名, 脚本路径, timeout, matcher)
hook_defs = [
    ("Stop",              "$HOOK_NOTIFY",       10,  None),
    ("SessionEnd",        "$HOOK_NOTIFY",       10,  None),
    ("PermissionRequest", "$HOOK_PERMISSION",   180, None),
    ("Notification",      "$HOOK_NOTIFICATION", 10,  "permission_prompt|idle_prompt"),
]

settings = {}
if os.path.exists(path):
    bak = path + ".bak." + datetime.now().strftime("%Y%m%d%H%M%S")
    shutil.copy2(path, bak)
    print(f"  已备份: {bak}", file=sys.stderr)
    with open(path) as f:
        try: settings = json.load(f)
        except: settings = {}

if "hooks" not in settings:
    settings["hooks"] = {}

added = []
for event, cmd, timeout, matcher in hook_defs:
    if event not in settings["hooks"]:
        settings["hooks"][event] = []
    script_name = cmd.rsplit("/", 1)[-1]
    exists = any(
        script_name in h.get("command", "")
        for g in settings["hooks"][event]
        for h in g.get("hooks", [])
    )
    if not exists:
        entry = {"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}
        if matcher:
            entry["matcher"] = matcher
        settings["hooks"][event].append(entry)
        added.append(event)

with open(path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)

if added:
    print(f"  已注册 Hook: {', '.join(added)}", file=sys.stderr)
else:
    print("  所有 Hook 已存在，跳过", file=sys.stderr)
PYEOF

ok "Claude Code Hook 已注册"

# ══════════════════════════════════════════════════════
step "安装完成！"
# ══════════════════════════════════════════════════════

echo ""
echo -e "${GREEN}┌─────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  claw-skill-cc 安装成功！                           │${NC}"
echo -e "${GREEN}├─────────────────────────────────────────────────────┤${NC}"
echo -e "${GREEN}│                                                     │${NC}"
echo -e "${GREEN}│  OpenClaw 侧:                                      │${NC}"
echo -e "${GREEN}│    ~/.openclaw/skills/$SKILL_NAME/   │${NC}"
echo -e "${GREEN}│    ~/.openclaw/data/claude-code-results/            │${NC}"
echo -e "${GREEN}│                                                     │${NC}"
echo -e "${GREEN}│  Claude Code 侧:                                   │${NC}"
echo -e "${GREEN}│    ~/.claude/settings.json (4 Hooks 已注册)          │${NC}"
echo -e "${GREEN}│                                                     │${NC}"
echo -e "${GREEN}├─────────────────────────────────────────────────────┤${NC}"
echo -e "${GREEN}│  可选：设置环境变量以启用 wake event                │${NC}"
echo -e "${GREEN}│    export OPENCLAW_TOKEN=<your-gateway-token>       │${NC}"
echo -e "${GREEN}│    export OPENCLAW_GATEWAY=http://127.0.0.1:18789   │${NC}"
echo -e "${GREEN}│                                                     │${NC}"
echo -e "${GREEN}│  重启 OpenClaw 使 skill 生效                       │${NC}"
echo -e "${GREEN}└─────────────────────────────────────────────────────┘${NC}"
echo ""
echo "卸载: bash $SCRIPT_DIR/install.sh --uninstall"
