#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GitHub Copilot CLI 入口(hooks 的 PreToolUse 事件)。

判定逻辑在 core.py,规则在 rules.py —— 本文件只负责把等级翻译成 Copilot 协议:
  block → 响铃 + 命令行提示(core.notify_user)+ permissionDecision: deny
  warn  → 响铃 + permissionDecision: ask(交给 Copilot 弹 hook 确认框)
  其余  → 不输出任何东西(「空输出 = 走默认行为」,不替用户免掉它自己的审批)

输入:安装脚本用的是 **PascalCase** 事件名 PreToolUse,所以 payload 是 VS Code 兼容格式
(snake_case:hook_event_name / session_id / cwd / tool_name / tool_input),tool_name 报的是
Claude 工具名(shell 就是 Bash)—— 和 Claude Code 完全同构,所以能直接用 core.get_command
和 core.TOOL_NAMES。用 camelCase 的 preToolUse 则是 toolName / toolArgs,本文件不管那一档。

输出:平铺的 {permissionDecision, permissionDecisionReason},**没有** Claude 那层
hookSpecificOutput 包装(官方 hooks reference 里压根没有这个词),所以不能复用 danger-guard.py。

⚠ 最要命的一条:Copilot 对 preToolUse 命令钩子是 **fail-closed** —— 崩溃或任何非 0 退出码
(含 exit 2)都会直接拒掉这次工具调用,哪怕 stdout 写着 allow。也就是说本脚本一旦装坏
(core.py 丢了、python 版本不对),Copilot 会把每条命令都拦死,不是放行。所以这里连 import
都包在 try 里,任何异常一律静默 exit 0,宁可当次不守卫也不能把客户端锁死。
(超时是唯一例外:官方规定 timeout 一律 fail-open。)
"""

import json
import os
import sys

try:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import core
except Exception:
    sys.exit(0)   # 装坏了也不能把 Copilot 锁死,见上面的 fail-closed 说明


def emit(decision, reason):
    print(json.dumps({
        "permissionDecision": decision,
        "permissionDecisionReason": "[命令守卫] " + reason,
    }, ensure_ascii=False))


def main():
    data = json.loads(sys.stdin.read())
    if data.get("tool_name") not in core.TOOL_NAMES:
        return
    cmd = core.get_command(data)
    if not cmd.strip():
        return

    level, reason = core.classify(cmd, data.get("cwd") or os.getcwd())
    if level == "block":
        core.play_sound()
        core.notify_user(cmd, reason)
        emit("deny", reason)
    elif level == "warn":
        # 非 bypass 才会走到这里:bypass 下 warn 已在 core 里升成 block
        core.play_sound()
        emit("ask", reason)
    # allowlist / safe:静默,交回 Copilot 自己的审批


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
