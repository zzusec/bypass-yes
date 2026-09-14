#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Codex CLI 入口(PreToolUse + PermissionRequest hook)。

用法:danger-guard-codex.py PreToolUse|PermissionRequest  (事件名由 hooks.json 写死)

判定逻辑在 core.py,规则在 rules.py。Codex 与 Claude 的唯一差别是决策通道:
Codex 的 PreToolUse 只认 deny —— 输出 permissionDecision:allow / ask 会被当成
unsupported 报错(Codex ≥0.144 实测)。所以「危险 → 弹确认」这一档在这里只能响铃 +
静默,真正的确认框由 ~/.codex/rules/danger-guard.rules 的 prompt 档或沙箱提权流程弹出。

PermissionRequest 事件则是「自动点允许」的通道:安全命令直接放行,毁灭级直接拒绝,
危险命令保持沉默让原生确认框弹出。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core  # noqa: E402


def out_pretooluse(decision, reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": "[命令守卫] " + reason,
        }
    }, ensure_ascii=False))


def out_permission(behavior, message=None):
    decision = {"behavior": behavior}
    if message:
        decision["message"] = "[命令守卫] " + message
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": decision,
        }
    }, ensure_ascii=False))


def main():
    data = json.loads(sys.stdin.read())
    event = (sys.argv[1] if len(sys.argv) > 1 else "") or data.get("hook_event_name", "") or "PreToolUse"
    if data.get("tool_name") not in core.TOOL_NAMES:
        return
    cmd = core.get_command(data)
    if not cmd.strip():
        return

    level, reason = core.classify(cmd, data.get("cwd") or os.getcwd())

    if event == "PermissionRequest":
        if level == "block":
            core.play_sound()
            out_permission("deny", reason)
        elif level in ("allowlist", "safe"):
            out_permission("allow")
        return

    if level == "block":
        core.play_sound()
        core.notify_user(cmd, reason)
        out_pretooluse("deny", reason)
    elif level == "warn":
        # 只有 approval_policy 不是 never 才走得到这里 —— 那种情况客户端自己能弹确认。
        # never 时 warn 已在 core.classify 里升成 block,和 Claude 系的处理保持一致。
        core.play_sound()   # 不输出:交给 rules 的 prompt 档 / 沙箱提权弹确认
    # allowlist / safe / passthrough:静默放行


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
