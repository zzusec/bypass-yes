#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Crush 入口(crush.json 的 PreToolUse hook)。

判定逻辑在 core.py,规则在 rules.py —— 本文件只负责把等级翻译成 Crush 协议:
  block / warn → 响铃 + 命令行提示(core.notify_user)+ decision: deny
  其余         → 不输出任何东西(静默放行,交给 Crush 自己的审批)

输入形状和 Claude 系同构({event, session_id, cwd, tool_name, tool_input}),只有工具名
是小写 bash,所以照样能用 core.get_command。

为什么 warn 也 deny:Crush 的 decision 只有 allow / deny / none 三档,**没有 ask**
(none = 不表态,等于交回它自己的审批)。而 Crush 有 `--yolo` / `skip_permission_requests`,
那时它自己也不会问 —— 与其赌用户没开 yolo,不如按项目既定策略把 WARN 一律硬拒:
想放行某类命令就写进 allowlist.txt。

Crush 也认 Claude 的 hookSpecificOutput 格式,但那边的 ask 在 Crush 词汇表里不存在
(大概率被当成 none 放过去),所以这里用 Crush 原生的 {decision, reason},不用兼容格式。

退出码:Crush 规定 0=解析 stdout 的 JSON、2=拦截(stderr 当原因)、其余=非阻断错误。
本脚本正常路径都走 0;解析出错时按 fail-open 静默退出 0,不阻断 Crush。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core  # noqa: E402


def emit(reason):
    print(json.dumps({
        "decision": "deny",
        "reason": "[命令守卫] " + reason + " —— 别重试,换别的做法。",
    }, ensure_ascii=False))


def main():
    data = json.loads(sys.stdin.read())
    if data.get("tool_name") != "bash":   # Crush 的 shell 工具就叫 bash(小写)
        return
    cmd = core.get_command(data)
    if not cmd.strip():
        return

    # bypass=True:warn 升 block(Crush 没有 ask 这一档)
    level, reason = core.classify(cmd, data.get("cwd") or os.getcwd(), bypass=True)
    if level in ("block", "warn"):
        core.play_sound()
        core.notify_user(cmd, reason)
        emit(reason)
    # allowlist / safe:静默放行


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
