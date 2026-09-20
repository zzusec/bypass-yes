#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""agy(Antigravity CLI)入口(hooks.json 的 PreToolUse 事件)。

判定逻辑在 core.py,规则在 rules.py —— 本文件只负责把等级翻译成 agy 协议:
  block → 响铃 + 命令行提示(core.notify_user)+ decision: deny
  warn  → 响铃 + decision: force_ask(交给 agy 弹确认框)
  其余  → 不输出(静默放行,不替用户免掉 agy 自己的审批)

输入形状和别家都不一样:工具名叫 run_command,命令在 toolCall.args.CommandLine
(注意 args 里的键是大驼峰,外层元数据才是小驼峰/protojson)。cwd 在 toolCall.args.Cwd,
缺失时退到 workspacePaths[0] —— headless(-p)下 workspacePaths 实测可能是空数组。

安全命令为什么「不输出」而不是 decision: allow:实测 agy 对空 stdout 是放行(走它自己的
审批),而输出一个没有 decision 的 JSON(比如 {})会被当成拦截。所以静默既不越权放行、
也不会误伤。

warn 为什么用 force_ask 不用 ask:agy 的 ask 会命中「Always Allow」缓存 ——
用户只要对某条 git reset --hard 点过一次「总是允许」,以后守卫就形同虚设。
force_ask 忽略缓存,每次都弹。

已知边界:turbo(`agy --dangerously-skip-permissions`)下确认框会被吞,那时 WARN 就是
静默执行。这种场景启动前 export DANGER_GUARD_BYPASS=1,守卫会把 WARN 升成 deny;
或者把要放行的命令写进 allowlist.txt。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core  # noqa: E402


def emit(decision, reason):
    print(json.dumps({
        "decision": decision,
        "reason": "[命令守卫] " + reason,
    }, ensure_ascii=False))


def get_cwd(data, args):
    cwd = args.get("Cwd")
    if isinstance(cwd, str) and cwd:
        return cwd
    paths = data.get("workspacePaths") or []
    if paths and isinstance(paths[0], str):
        return paths[0]
    return os.getcwd()


def main():
    data = json.loads(sys.stdin.read())
    call = data.get("toolCall") or {}
    if call.get("name") != "run_command":
        return
    args = call.get("args") or {}
    cmd = args.get("CommandLine", "")
    if not isinstance(cmd, str) or not cmd.strip():
        return

    level, reason = core.classify(cmd, get_cwd(data, args))
    if level == "block":
        core.play_sound()
        core.notify_user(cmd, reason)
        emit("deny", reason)
    elif level == "warn":
        core.play_sound()
        emit("force_ask", reason)
    # allowlist / safe:静默,由 agy 自己的审批决定


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
