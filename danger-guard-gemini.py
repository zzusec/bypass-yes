#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Gemini CLI 入口(BeforeTool hook)。

判定逻辑在 core.py,规则在 rules.py —— 本文件只负责把等级翻译成 Gemini 协议:
  block / warn → 响铃 + 命令行提示(core.notify_user)+ decision: deny
  其余         → 不输出任何东西(静默放行,交给 Gemini 自己的审批)

为什么 warn 也 deny:Gemini 的 hook 输出只有 allow / deny 两档,没有 ask
(也就不存在"弹个确认框"这一档)。非 yolo 模式下 Gemini 自己会对 shell 命令弹确认,
但 yolo 模式下什么都弹不出来 —— 与其赌客户端行为,不如按项目既定策略把 WARN 一律
硬拒:想放行某类命令就写进 allowlist.txt。

放行为什么是「不输出」而不是 decision: allow:显式 allow 有可能替用户把 Gemini 自己的
确认框也一并免掉(那就成了放宽权限),静默则不干涉客户端原有的审批。

退出码:Gemini 规定 0=成功(解析 stdout 的 JSON)、2=拦截(stderr 当原因)。
本脚本正常路径都走 0;解析出错时按 fail-open 静默退出 0,不阻断 Gemini。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core  # noqa: E402


def emit(reason):
    print(json.dumps({
        "decision": "deny",
        "reason": "[命令守卫] " + reason,               # 给模型看的,作为工具错误返回
        "systemMessage": "[命令守卫] 已拦截:" + reason,  # 给终端里的人看的
    }, ensure_ascii=False))


def main():
    data = json.loads(sys.stdin.read())
    if data.get("tool_name") not in core.TOOL_NAMES:   # Gemini 的 shell 工具叫 run_shell_command
        return
    cmd = core.get_command(data)
    if not cmd.strip():
        return

    # bypass=True:warn 升 block(Gemini 没有 ask 这一档)
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
