#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Claude Code / CodeBuddy / zcode / Qoder / Factory droid 入口(PreToolUse hook)。

判定逻辑在 core.py,规则在 rules.py —— 本文件只负责把等级翻译成 Claude 系协议:
  block → 响铃 + 命令行提示(core.notify_user)+ permissionDecision: deny
  warn  → 响铃 + permissionDecision: ask
          只有非 bypass 会走到这里:bypass 下 warn 已在 core.classify 里升成 block,
          因为客户端那边不弹 ask(实测会静默执行)
  其余  → 不输出任何东西(静默放行)

注意:Claude Code(含 auto 模式)不接受 permissionDecision:"allow",会报 unsupported
并导致 PreToolUse failed。所以放行必须是「不打印 JSON」。

CodeBuddy、zcode、Qoder 的 hook 协议与 Claude 完全一致(同样读 hookSpecificOutput
.permissionDecision 的 deny/ask,事件名同为 PreToolUse,输入 JSON 同构,工具名同为 Bash),
所以四家共用这一个入口。zcode 的运行时代码实测:hook 的 deny 永远生效,yolo 也压不住;
本项目把 zcode 当 bypass 处理(core.is_bypass_mode 读 setting.json 的 permission.mode),
warn 一律硬拒,行为可预期。Qoder 同理(读 settings.json 的 general.defaultPermissionMode)。

Factory droid 的 hook API 和 Claude Code 一样(同样 PreToolUse / hookSpecificOutput
.permissionDecision),差别只有两处:shell 工具叫 Execute(已进 core.TOOL_NAMES),
以及 payload 里直接带 permission_mode,不用去读配置文件猜。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core  # noqa: E402


def emit(decision, reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": "[命令守卫] " + reason,
        }
    }, ensure_ascii=False))


def main():
    data = json.loads(sys.stdin.read())
    if data.get("tool_name") not in core.TOOL_NAMES:
        return
    cmd = core.get_command(data)
    if not cmd.strip():
        return

    # Factory droid 在 payload 里直接带 permission_mode(off / spec / auto-low /
    # auto-medium / auto-high);auto-* 都是「自动批准」档,ask 弹不出来,所以按 bypass 处理。
    # 其它几家不发这个字段,bypass=None 时仍走 core.is_bypass_mode() 读各自配置文件。
    mode = data.get("permission_mode")
    bypass = True if isinstance(mode, str) and mode.startswith("auto") else None

    level, reason = core.classify(cmd, data.get("cwd") or os.getcwd(), bypass=bypass)
    if level == "block":
        core.play_sound()
        core.notify_user(cmd, reason)
        emit("deny", reason)
    elif level == "warn":
        # 只有非 bypass 才会走到这里:bypass 下 warn 已在 core 里升成 block 了
        core.play_sound()
        emit("ask", reason)
    # allowlist / safe / passthrough:静默,由权限模式或静态 deny 决定


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
