# claw-skill-cc

OpenClaw Skill: Claude Code Orchestrator — 让 OpenClaw 调度 Claude Code CLI 执行编码任务。

## 架构

```
OpenClaw（调度层 / 技术 PM）
  ├── 理解需求、拆解任务
  ├── exec 调用 Claude Code CLI
  ├── 每 5-10 秒轮询输出
  ├── 自主决策（遇到问题时）
  └── 整合结果、汇报进度
        ↓
Claude Code（执行层 / 执行工程师）
  ├── 持续会话（acpx -s）
  ├── 执行编码任务
  └── NDJSON 流式输出
```

## 前置条件

### 必需

- [OpenClaw](https://github.com/openclaw/openclaw) 已安装并运行
- **Claude Code CLI** — 至少安装其中一种:
  ```bash
  # 方式 1: 直接安装 Claude Code CLI（推荐）
  npm install -g @anthropic-ai/claude-code

  # 方式 2: 通过 acpx（OpenClaw 内置 ACPX 插件通常已包含）
  # 无需额外安装
  ```

### 可选

- `acpx` — 用于持续会话模式（OpenClaw 内置 ACPX 插件通常已包含）

## 安装

将此 skill 目录复制到 OpenClaw 的 skills 目录:

```bash
# 方式 1: 直接复制
cp -r claw-skill-cc ~/.openclaw/skills/claude-code-orchestrator

# 方式 2: 符号链接（开发时推荐）
ln -s $(pwd)/claw-skill-cc ~/.openclaw/skills/claude-code-orchestrator
```

给脚本添加执行权限:

```bash
chmod +x ~/.openclaw/skills/claude-code-orchestrator/scripts/*.sh
```

重启 OpenClaw 使 skill 生效。

## 使用方式

在 OpenClaw 对话中直接说:

```
帮我用 Claude Code 实现一个用户注册功能
```

```
让 Claude Code 重构 src/auth 模块
```

```
用 CC 修复 #123 号 bug
```

OpenClaw 会自动:
1. 拆解任务为可执行的子任务
2. 启动 Claude Code 后台执行
3. 每 5-10 秒轮询进度
4. 遇到问题时自主决策
5. 完成后汇总报告

## 执行模式

| 模式 | 命令 | 适用场景 |
|------|------|---------|
| Direct | `claude --print` | 大多数场景，简单高效 |
| ACPX Session | `acpx claude -s <name>` | 需要多轮交互的复杂任务 |
| ACPX One-shot | `acpx claude exec` | 一次性任务 |

## 项目结构

```
claw-skill-cc/
├── SKILL.md                  # 核心技能定义（OpenClaw 读取）
├── scripts/
│   ├── cc-invoke.sh          # 调用 Claude Code CLI
│   ├── cc-poll.sh            # 轮询输出 + 完成检测
│   └── cc-session.sh         # 会话管理（创建/恢复/关闭）
├── references/
│   └── task-strategy.md      # 任务拆解策略参考
└── README.md                 # 本文件
```

## 自主决策边界

### OpenClaw 自动处理（不问用户）

- 依赖安装失败
- 测试/编译错误
- 文件冲突
- 路径/配置问题

### 需要用户确认

- 权限不足（sudo 等）
- 涉及生产环境
- 需要 API Key 等敏感信息
- 架构设计决策

## 作者

XuJiaKai
