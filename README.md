# claw-skill-cc

OpenClaw Skill: Claude Code Orchestrator — **Dispatch 模式**，发射后不管，完成自动回报。

## 架构

```
OpenClaw（调度层 / 技术 PM）
  ├── 理解需求、拆解任务
  ├── dispatch 到 Claude Code（发射后不管）
  └── 收到 wake event → 读 latest.json → 处理结果
        ↓
Claude Code（执行层 / 执行工程师）
  ├── 独立执行编码任务
  ├── 支持 Agent Teams 协作
  └── 完成 → Stop Hook 自动触发
        ↓
Stop Hook（回调层）
  ├── 写 latest.json（数据通道 — 快递柜）
  └── 发 wake event（信号通道 — 门铃）
```

### 双通道设计

| 只有 latest.json | 只有 wake event | 两者配合 |
|-----------------|----------------|---------|
| 结果存了，AGI 不知道 | AGI 醒了，不知细节 | AGI 立刻醒来读完整结果 ✅ |
| 要等 heartbeat 发现 | 消息长度有限 | 实时 + 完整 |

**容错**: wake event 失败不影响 latest.json，AGI 最迟在下次 heartbeat 也能读到。

## 前置条件

- [OpenClaw](https://github.com/openclaw/openclaw) 已安装并运行
- **Claude Code CLI**: `npm install -g @anthropic-ai/claude-code`
- **Python 3**（脚本依赖）

## 安装

```bash
# 1. 链接 skill 到 OpenClaw
ln -s $(pwd) ~/.openclaw/skills/claude-code-orchestrator

# 2. 设置执行权限
chmod +x scripts/*.sh scripts/*.py hooks/*.sh

# 3. 注册 Claude Code Hooks（合并到 ~/.claude/settings.json）
# 参考 hooks/claude-settings.json 的内容，
# 将 Stop 和 SessionEnd hook 添加到你的 ~/.claude/settings.json
```

### Hook 配置

将以下内容合并到 `~/.claude/settings.json`：

```json
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "~/.openclaw/skills/claude-code-orchestrator/hooks/notify-agi.sh", "timeout": 10}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "~/.openclaw/skills/claude-code-orchestrator/hooks/notify-agi.sh", "timeout": 10}]}]
  }
}
```

### 环境变量（可选）

```bash
export CC_RESULT_DIR=~/.openclaw/data/claude-code-results  # 结果目录
export OPENCLAW_GATEWAY=http://127.0.0.1:18789             # Gateway 地址
export OPENCLAW_TOKEN=your-token-here                       # Gateway token
```

## 使用方式

在 OpenClaw 对话中直接说：

```
dispatch 一个任务到 Claude Code：构建一个 Markdown 转 HTML 的工具，要有测试
```

```
用 Claude Code 构建一个 REST API，FastAPI + SQLite，管理 TODO 列表
```

```
用 Claude Code 的 Agent Teams 协作模式构建一个落沙模拟游戏
```

OpenClaw 会自动：
1. 拆解任务
2. 调用 `cc-dispatch.sh` 派发（发射后不管）
3. Claude Code 完成后 Hook 自动写 `latest.json` + 发 wake event
4. OpenClaw 被唤醒，读取结果，汇总报告

## 项目结构

```
claw-skill-cc/
├── SKILL.md                      # 核心技能定义（OpenClaw 读取）
├── hooks/
│   ├── notify-agi.sh             # Stop Hook（写结果 + 发通知）
│   └── claude-settings.json      # Claude Code hooks 配置参考
├── scripts/
│   ├── cc-dispatch.sh            # Bash 版任务派发
│   ├── cc-dispatch.py            # Python 版任务派发（支持 Agent Teams）
│   ├── cc-result.sh              # 读取/查询结果
│   └── cc-session.sh             # ACPX 会话管理
├── references/
│   └── task-strategy.md          # 任务拆解策略参考
└── README.md
```

## 数据流

```
dispatch-claude-code.sh
  ├─ 写入 task-meta.json（任务名、参数）
  ├─ 启动 Claude Code（nohup 后台）
  │   └─ Agent Teams lead + sub-agents 运行
  │
  └─ Claude Code 完成 → Stop Hook 自动触发
      │
      ├─ notify-agi.sh 执行：
      │   ├─ 读取 task-meta.json + task-output.txt
      │   ├─ 写入 latest.json（完整结果）
      │   ├─ 发送 wake event → OpenClaw Gateway
      │   └─ 写入 pending-wake.json（备选通道）
      │
      └─ AGI 读取 latest.json 处理结果
```

## 结果文件

任务完成后，结果写入 `~/.openclaw/data/claude-code-results/latest.json`：

```json
{
  "session_id": "abc123",
  "timestamp": "2026-04-08T17:00:00+00:00",
  "task_name": "todo-api",
  "cwd": "/home/user/projects/todo-api",
  "event": "Stop",
  "output": "Claude Code 完整输出...",
  "status": "done"
}
```

## 作者

XuJiaKai
