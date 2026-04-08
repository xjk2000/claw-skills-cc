---
name: claude-code-orchestrator
description: 'Orchestrate Claude Code CLI as an execution engine via OpenClaw agent dispatch. Use when: (1) delegating coding tasks to Claude Code with real-time progress monitoring, (2) decomposing complex requirements into subtasks for Claude Code execution, (3) managing persistent Claude Code sessions with auto-recovery and decision-making, (4) running multi-step coding workflows where OpenClaw acts as tech PM and Claude Code as execution engineer. Triggers on: "run in claude code", "let claude code handle this", "delegate to claude code", "use cc to build", "start a claude code session". NOT for: simple one-liner fixes, reading code, non-coding tasks, or when user wants to run Claude Code manually.'
---

# Claude Code Orchestrator

OpenClaw 作为技术 PM 调度 Claude Code CLI 执行编码任务。

## 架构

```
OpenClaw Agent（调度层）
  ├── 理解需求（LLM）
  ├── 拆解任务
  ├── exec 调用 Claude Code
  ├── 轮询监控执行过程
  ├── 自主决策（遇到问题时）
  └── 整合结果
  ↓
Claude Code CLI（执行层）
  ├── 持续会话（-s <name>）
  ├── 执行编码任务
  └── 流式输出（NDJSON / --print）
```

## 两种执行模式

### 模式 1: Direct Claude CLI（推荐，简单高效）

适用于大多数场景，直接调用 `claude` CLI：

```bash
# 前台执行（短任务）
bash workdir:<project-path> command:"claude --print --permission-mode bypassPermissions --output-format stream-json '<task>'"

# 后台执行（长任务，推荐）
bash workdir:<project-path> background:true command:"claude --print --permission-mode bypassPermissions --output-format stream-json '<task>'"
```

关键参数：
- `--print`: 非交互模式，保留完整工具调用能力
- `--permission-mode bypassPermissions`: 跳过权限确认
- `--output-format stream-json`: NDJSON 流式输出，便于解析
- **不需要 PTY**

### 模式 2: ACPX Claude（持续会话）

适用于需要多轮交互的复杂任务：

```bash
# 创建/复用会话
ACPX_CMD="${ACPX_PLUGIN_ROOT:-$HOME/.openclaw/extensions/acpx}/node_modules/.bin/acpx"

# 持续会话模式
$ACPX_CMD claude -s <session-name> --cwd <project-path> --format quiet "<task>"

# 一次性执行
$ACPX_CMD claude exec --cwd <project-path> --format quiet "<task>"
```

## 执行流程

### Step 1: 任务拆解

收到用户需求后，先拆解为可执行的子任务。参考 [references/task-strategy.md](references/task-strategy.md) 获取拆解策略。

拆解原则：
- 每个子任务应该是 Claude Code 可独立完成的
- 子任务之间有明确的依赖关系和执行顺序
- 每个子任务有清晰的完成标准

### Step 2: 启动执行

对每个子任务，使用后台模式启动 Claude Code：

```bash
# 启动后台任务
bash workdir:<project-path> background:true command:"claude --print --permission-mode bypassPermissions --output-format stream-json '
<task-description>

完成后请输出: TASK_COMPLETE: <brief-summary>
如果遇到无法自行解决的问题，请输出: TASK_BLOCKED: <reason>
'"
# 记录返回的 sessionId
```

### Step 3: 轮询监控

每 5-10 秒轮询一次输出：

```bash
# 检查进度
process action:log sessionId:<id>

# 检查是否仍在运行
process action:poll sessionId:<id>
```

### Step 4: 输出解析与决策

解析 NDJSON 输出，识别关键标记：

| 标记 | 含义 | 动作 |
|------|------|------|
| `TASK_COMPLETE: ...` | 任务完成 | 收集结果，启动下一个子任务 |
| `TASK_BLOCKED: ...` | 遇到阻塞 | OpenClaw 自主分析并提供指导 |
| 进程退出 | 正常/异常结束 | 检查结果，决定重试或继续 |
| 超时（>10 分钟无新输出） | 可能卡死 | 检查输出，决定 kill 或等待 |

### Step 5: 自主决策

当 Claude Code 遇到问题时，OpenClaw 根据问题类型自主决策：

**自动处理（不问用户）：**
- 依赖安装失败 → 提供替代安装命令
- 测试失败 → 分析错误，指导修复
- 编译错误 → 分析错误信息，指导修正
- 文件冲突 → 基于需求理解指导解决
- 路径/配置问题 → 提供正确的路径/配置

**需要用户确认：**
- 权限不足（需要 sudo 等）
- 涉及生产环境操作
- 需要 API Key 等敏感信息
- 架构设计决策（多种合理方案时）
- 费用相关操作

### Step 6: 结果整合

所有子任务完成后：
1. 汇总每个子任务的执行结果
2. 验证整体目标是否达成
3. 向用户报告完成状态和变更摘要

## 会话管理

### 命名规范

```
cc-<project>-<task-id>
```

示例：`cc-myapp-feat-auth`, `cc-myapp-fix-login`

### 并行执行

支持同时运行多个 Claude Code 实例处理不同子任务：

```bash
# 子任务 1: 后端 API
bash workdir:~/project background:true command:"claude --print --permission-mode bypassPermissions '实现用户认证 API...'"

# 子任务 2: 前端组件（无依赖关系时可并行）
bash workdir:~/project background:true command:"claude --print --permission-mode bypassPermissions '实现登录页面组件...'"

# 监控所有任务
process action:list
```

### 错误恢复

```bash
# Claude Code 进程异常退出时，检查最后输出
process action:log sessionId:<id> offset:-50

# 分析问题后，重新启动
bash workdir:<project-path> background:true command:"claude --print --permission-mode bypassPermissions '
继续之前的任务。上次执行到: <last-progress>
遇到的问题: <error-info>
请从这里继续: <next-step>
'"
```

## 完成通知

在任务 prompt 末尾追加通知指令，确保 OpenClaw 即时感知完成：

```bash
bash workdir:<project-path> background:true command:"claude --print --permission-mode bypassPermissions '
<task>

完成所有工作后，执行以下命令通知调度系统:
openclaw system event --text \"TASK_COMPLETE: <summary>\" --mode now
'"
```

## 规则

1. **绝不手动接管**: OpenClaw 是调度者，不直接写代码。如果 Claude Code 失败，重新指导它，而非自己动手
2. **耐心等待**: 不因为"慢"就 kill 进程，除非确认卡死（>10 分钟无输出）
3. **最小干预**: 只在真正需要时介入，让 Claude Code 自主完成尽可能多的工作
4. **保持上下文**: 向 Claude Code 传递足够的上下文，包括项目结构、技术栈、编码规范
5. **结果验证**: 每个子任务完成后验证结果，不盲目信任
6. **进度汇报**: 后台任务启动后告知用户正在做什么，完成/异常时及时更新
7. **安全边界**: 涉及权限、生产环境、敏感信息时必须请示用户
