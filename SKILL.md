---
name: claude-code-orchestrator
description: 'Dispatch coding tasks to Claude Code CLI with fire-and-forget pattern. Use when: (1) delegating coding tasks to Claude Code without polling, (2) decomposing complex requirements into subtasks for Claude Code, (3) running Agent Teams collaborative builds, (4) any workflow where OpenClaw acts as tech PM and Claude Code as execution engineer. Triggers on: "dispatch to claude code", "run in claude code", "let claude code handle", "use cc to build", "agent teams build". NOT for: simple one-liner fixes, reading code, non-coding tasks.'
---

# Claude Code Orchestrator — Dispatch 模式

核心思想：**发射后不管，完成自动回报**。

## 架构

```
OpenClaw Agent（调度层 / 技术 PM）
  ├── 理解需求、拆解任务
  ├── exec dispatch 到 Claude Code（发射后不管）
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

## 双通道设计

```
latest.json = 数据通道（存完整结果，无大小限制）
wake event  = 信号通道（通知 AGI 立刻来读）
```

| 只有 latest.json | 只有 wake event | 两者配合 |
|-----------------|----------------|---------|
| 结果存了，AGI 不知道 | AGI 醒了，不知细节 | AGI 立刻醒来读完整结果 ✅ |
| 要等 heartbeat 发现 | 消息长度有限 ~300 字 | 实时 + 完整 |

容错：wake event 失败不影响 latest.json，AGI 最迟在下次 heartbeat 也能读到。

## 执行流程

### Step 1: 任务拆解

收到需求后，拆解为子任务。参考 [references/task-strategy.md](references/task-strategy.md)。

### Step 2: Dispatch（发射后不管）

调用 `scripts/cc-dispatch.sh` 派发任务，**不等待完成**：

```bash
# 基础任务
bash workdir:<skill-path>/scripts command:"./cc-dispatch.sh \
  -p '实现一个 Python 命令行计算器，支持加减乘除和历史记录' \
  -n 'calculator' \
  --permission-mode bypassPermissions \
  --workdir /path/to/project"

# Agent Teams 协作任务
bash workdir:<skill-path>/scripts command:"./cc-dispatch.sh \
  -p '构建 REST API，FastAPI + SQLite，管理 TODO 列表' \
  -n 'todo-api' \
  --agent-teams \
  --teammate-mode auto \
  --permission-mode bypassPermissions \
  --workdir /path/to/project"
```

Dispatch 后立即告知用户任务已派发，无需轮询。

### Step 3: 等待回调

Claude Code 完成后，Stop Hook 自动触发：
1. 写入 `latest.json`（完整结果）
2. 发送 wake event 通知 OpenClaw Gateway

### Step 4: 读取结果

AGI 被唤醒后，读取结果文件：

```bash
bash command:"cat $RESULT_DIR/latest.json"
```

结果 JSON 格式：

```json
{
  "session_id": "abc123",
  "timestamp": "2026-04-08T17:00:00+08:00",
  "task_name": "calculator",
  "cwd": "/path/to/project",
  "event": "Stop",
  "output": "Claude Code 完整输出...",
  "status": "done"
}
```

### Step 5: 自主决策

根据结果决定下一步：

**自动处理（不问用户）：**
- 编译/测试失败 → 构造修复 prompt，重新 dispatch
- 依赖缺失 → 补充安装指令，重新 dispatch
- 部分完成 → 基于输出构造后续任务

**需要用户确认：**
- 权限不足（sudo 等）
- 涉及生产环境
- 需要 API Key 等敏感信息
- 架构设计决策

### Step 6: 结果整合

所有子任务完成后，汇总报告给用户。

## 脚本说明

### cc-dispatch.sh

派发任务到 Claude Code，支持基础和 Agent Teams 模式：

```bash
scripts/cc-dispatch.sh \
  -p "任务描述" \
  -n "任务名称" \
  --workdir /project/path \
  --permission-mode bypassPermissions \
  [--agent-teams] \
  [--teammate-mode auto]
```

工作流程：
1. 写入 `task-meta.json`（任务名、参数）
2. 启动 Claude Code（后台 nohup）
3. 立即返回，不等待

### cc-dispatch.py

Python 版派发，功能同上但支持更复杂的参数组合。

### cc-result.sh

读取和解析 latest.json 结果。

### cc-session.sh

ACPX 持续会话管理（创建/列出/恢复/关闭）。

## Hook 机制

### 注册（~/.claude/settings.json）

```json
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "<skill-path>/hooks/notify-agi.sh", "timeout": 10}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "<skill-path>/hooks/notify-agi.sh", "timeout": 10}]}]
  }
}
```

### notify-agi.sh 流程

1. 读取 `task-meta.json` + Claude Code 输出
2. 写入 `latest.json`（完整结果）
3. 发送 wake event 到 OpenClaw Gateway
4. 使用 `.hook-lock` 防重复（Stop + SessionEnd 30 秒内去重）

### 防重复机制

Stop 和 SessionEnd 都会触发 Hook。使用 `.hook-lock` 文件去重：
- 30 秒内重复触发自动跳过
- 只处理第一个事件（通常是 Stop）

## 并行 Dispatch

可同时派发多个不相关的子任务：

```bash
# 子任务 1: 后端
bash workdir:<skill-path>/scripts command:"./cc-dispatch.sh -p '实现 API...' -n 'backend' --workdir ~/project"

# 子任务 2: 前端（无依赖，并行）
bash workdir:<skill-path>/scripts command:"./cc-dispatch.sh -p '实现 UI...' -n 'frontend' --workdir ~/project"
```

每个任务完成时独立触发 Hook 回调。

## 规则

1. **发射后不管** — dispatch 后不轮询进程状态，等 Hook 回调
2. **绝不手动接管** — OpenClaw 是调度者，不直接写代码
3. **双通道容错** — latest.json（数据）+ wake event（信号），wake 失败不丢结果
4. **保持上下文** — dispatch 时传递充分的项目上下文和技术栈信息
5. **结果验证** — 收到回调后验证结果，不盲目信任
6. **进度汇报** — dispatch 后告知用户，收到结果后汇总报告
7. **安全边界** — 涉及权限、生产环境、敏感信息时必须请示用户
