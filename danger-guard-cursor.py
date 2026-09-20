#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cursor 入口(hooks.json 的 beforeShellExecution 事件)。

判定逻辑在 core.py,规则在 rules.py —— 本文件只负责把等级翻译成 Cursor 协议:
  block → 响铃 + 命令行提示(core.notify_user)+ permission: deny
  warn  → 响铃 + permission: ask(交给 Cursor 弹确认框)
  其余  → 不输出(静默放行,不替用户免掉 Cursor 自己的审批)

Cursor 的 beforeShellExecution 输入是 {hook_event_name, command, cwd, workspace_roots},
命令文本直接在顶层 command 字段里,没有 tool_name 这层 —— 所以不走 core.get_command。
cwd 可能为空,回退到 workspace_roots[0] 或当前目录。

已知边界:Cursor 在「自动执行 / 免确认」类设置下会吞掉 ask,那时 WARN 就是静默执行。
这种场景请在启动 Cursor 前 export DANGER_GUARD_BYPASS=1,守卫会把 WARN 升级成 deny;
或者把要放行的命令写进 allowlist.txt。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core  # noqa: E402


def emit(permission, reason):
    print(json.dumps({
        "permission": permission,
        "userMessage": "[命令守卫] " + reason,
        "agentMessage": "[命令守卫] 已拦下这条命令:" + reason + "。别重试,换别的做法。",
    }, ensure_ascii=False))


def get_cwd(data):
    cwd = data.get("cwd")
    if cwd:
        return cwd
    roots = data.get("workspace_roots") or []
    if roots and isinstance(roots[0], str):
        return roots[0]
    return os.getcwd()


def main():
    data = json.loads(sys.stdin.read())
    cmd = data.get("command", "")
    if isinstance(cmd, list):
        cmd = " ".join(str(x) for x in cmd)
    if not isinstance(cmd, str) or not cmd.strip():
        return

    level, reason = core.classify(cmd, get_cwd(data))
    if level == "block":
        core.play_sound()
        core.notify_user(cmd, reason)
        emit("deny", reason)
    elif level == "warn":
        core.play_sound()
        emit("ask", reason)
    # allowlist / safe:静默,由 Cursor 自己的审批决定


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
