#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pi 桥接入口 —— 被 ~/.pi/agent/extensions/command-guard.ts 调用。

pi 没有 Claude 那种「命令行 hook」,它的拦截点是 TypeScript 扩展的 tool_call 事件。
扩展不方便内嵌整套规则,所以由它在 bash 工具执行前调用本脚本,拿回分级结果再决定
放行 / 弹确认框 / 硬拦截。判定逻辑仍在 core.py,规则仍在 rules.py —— 五家同一份真源。

调用约定(pi.exec 没有 stdin,所以走 argv):
    python3 danger-guard-pi.py '<json>'
    # <json> = {"command": "rm -rf /", "cwd": "/Users/x/proj"}
    # 也兼容从 stdin 读同样的 JSON,方便手动调试:
    #   echo '{"command":"ls"}' | python3 danger-guard-pi.py

输出(stdout,单行 JSON):
    {"level": "block|warn|allowlist|safe", "reason": "..."}

扩展据此:block → {block:true};warn → ctx.ui.confirm(无 UI 则 block);其余 → 放行。

与 Claude/Codex 入口的差别:这里以 bypass=False 调 classify,warn 保持 warn ——
pi 的扩展能用 ctx.ui.confirm 弹真确认框,不像 bypass 模式那样会被客户端吞掉,
所以不必把 warn 提前升成 block。响铃对 block/warn 都会触发(和其他家一致)。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core  # noqa: E402


def read_payload():
    """优先 argv[1] 的 JSON;没有就读 stdin。解析失败返回 {}。"""
    raw = sys.argv[1] if len(sys.argv) > 1 else ""
    if not raw.strip():
        try:
            raw = sys.stdin.read()
        except Exception:
            raw = ""
    try:
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def emit(level, reason=""):
    print(json.dumps({"level": level, "reason": reason}, ensure_ascii=False))


def main():
    data = read_payload()
    cmd = data.get("command", "")
    if isinstance(cmd, list):
        cmd = " ".join(str(x) for x in cmd)
    if not isinstance(cmd, str) or not cmd.strip():
        emit("safe")
        return

    cwd = data.get("cwd") or os.getcwd()
    # bypass=False:warn 保持 warn,交给扩展的 ctx.ui.confirm 弹真确认框
    level, reason = core.classify(cmd, cwd, bypass=False)
    if level in ("block", "warn"):
        core.play_sound()
    emit(level, reason)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # 与其它入口一致:出错不阻断 pi(fail-open),静默按 safe 放行
        emit("safe")
        sys.exit(0)
