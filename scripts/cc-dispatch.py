#!/usr/bin/env python3
"""
cc-dispatch.py — Python 版 Claude Code 任务派发（支持 Agent Teams）

用法:
    python3 cc-dispatch.py --prompt "任务描述" --name "任务名" [options]

参数:
    --prompt, -p          任务描述（必需）
    --name, -n            任务名称（必需）
    --workdir, -w         工作目录，默认当前目录
    --permission-mode     权限模式，默认 bypassPermissions
    --agent-teams         启用 Agent Teams 协作模式
    --teammate-mode       Agent Teams 模式: auto(默认) | manual
    --allowed-tools       允许的工具列表（逗号分隔）
    --model               指定模型
    --max-turns           最大对话轮数

工作流程:
    1. 写入 task-meta.json（任务元数据）
    2. 启动 Claude Code（子进程，后台运行）
    3. 立即返回派发信息
    4. Claude Code 完成后 Stop Hook 自动回调

作者: XuJiaKai
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def get_result_dir():
    """获取结果文件目录"""
    return Path(os.environ.get(
        "CC_RESULT_DIR",
        os.path.expanduser("~/.openclaw/data/claude-code-results")
    ))


def check_claude_cli():
    """检查 claude CLI 是否可用"""
    if not shutil.which("claude"):
        print("ERROR: claude CLI 未安装。请运行: npm install -g @anthropic-ai/claude-code",
              file=sys.stderr)
        sys.exit(1)


def write_task_meta(result_dir, args):
    """写入任务元数据"""
    meta = {
        "task_name": args.name,
        "prompt": args.prompt,
        "workdir": str(args.workdir),
        "permission_mode": args.permission_mode,
        "agent_teams": args.agent_teams,
        "teammate_mode": args.teammate_mode,
        "dispatched_at": datetime.now(timezone.utc).isoformat(),
        "pid": None,
    }
    meta_path = result_dir / "task-meta.json"
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    return meta_path


def build_claude_command(args):
    """构建 Claude Code CLI 命令"""
    cmd = ["claude", "--print"]
    cmd.extend(["--permission-mode", args.permission_mode])
    cmd.extend(["--output-format", "text"])

    if args.agent_teams:
        cmd.append("--agent-teams")
        cmd.extend(["--teammate-mode", args.teammate_mode])

    if args.allowed_tools:
        cmd.extend(["--allowed-tools", args.allowed_tools])

    if args.model:
        cmd.extend(["--model", args.model])

    if args.max_turns:
        cmd.extend(["--max-turns", str(args.max_turns)])

    cmd.append(args.prompt)
    return cmd


def dispatch(args):
    """派发任务到 Claude Code"""
    check_claude_cli()

    workdir = Path(args.workdir).resolve()
    if not workdir.is_dir():
        print(f"ERROR: 工作目录不存在: {workdir}", file=sys.stderr)
        sys.exit(1)

    result_dir = get_result_dir()
    result_dir.mkdir(parents=True, exist_ok=True)

    # 写入任务元数据
    meta_path = write_task_meta(result_dir, args)

    # 输出文件
    output_file = result_dir / "task-output.txt"

    # 构建命令
    cmd = build_claude_command(args)

    mode = f"Agent Teams ({args.teammate_mode})" if args.agent_teams else "单 Agent"
    print(f"=== Claude Code Dispatch ===", file=sys.stderr)
    print(f"任务: {args.name}", file=sys.stderr)
    print(f"目录: {workdir}", file=sys.stderr)
    print(f"模式: {mode}", file=sys.stderr)
    print(f"============================", file=sys.stderr)

    # 启动 Claude Code（后台子进程）
    env = os.environ.copy()
    env["CC_RESULT_DIR"] = str(result_dir)
    env["CC_TASK_META"] = str(meta_path)

    with open(output_file, "w") as out_f:
        process = subprocess.Popen(
            cmd,
            cwd=str(workdir),
            stdout=out_f,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,  # 脱离父进程，独立运行
        )

    # 更新 meta 写入 PID
    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)
    meta["pid"] = process.pid
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)

    print(f"[dispatch] 任务已派发，PID: {process.pid}", file=sys.stderr)
    print(f"[dispatch] 输出文件: {output_file}", file=sys.stderr)
    print(f"[dispatch] 结果将写入: {result_dir}/latest.json", file=sys.stderr)

    # 输出 JSON 到 stdout
    result = {
        "task_name": args.name,
        "pid": process.pid,
        "workdir": str(workdir),
        "output_file": str(output_file),
        "result_dir": str(result_dir),
        "status": "dispatched",
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(
        description="派发任务到 Claude Code（发射后不管）"
    )
    parser.add_argument("-p", "--prompt", required=True, help="任务描述")
    parser.add_argument("-n", "--name", required=True, help="任务名称")
    parser.add_argument("-w", "--workdir", default=os.getcwd(), help="工作目录")
    parser.add_argument("--permission-mode", default="bypassPermissions",
                        help="权限模式")
    parser.add_argument("--agent-teams", action="store_true",
                        help="启用 Agent Teams 协作模式")
    parser.add_argument("--teammate-mode", default="auto",
                        choices=["auto", "manual"], help="Agent Teams 模式")
    parser.add_argument("--allowed-tools", default="", help="允许的工具（逗号分隔）")
    parser.add_argument("--model", default="", help="指定模型")
    parser.add_argument("--max-turns", type=int, default=None, help="最大对话轮数")

    args = parser.parse_args()
    dispatch(args)


if __name__ == "__main__":
    main()
