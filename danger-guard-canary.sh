#!/bin/sh
# 临时 canary(取证用,不属于守卫本体)
#
# 干两件事:把守卫被真实调用的证据记一行日志,然后把判定原样交给同目录的守卫入口。
# 行为和没有 canary 时一致 —— 放行仍无输出,拦截仍按各家协议输出。
#
# 用法:拷到客户端的 hooks 目录,再把该家配置里的 hook 命令指向它(用绝对路径)。
#   各家入口文件名不同,脚本会自动找:
#     danger-guard.py         Claude Code / CodeBuddy / zcode / Qoder
#     danger-guard-gemini.py  Gemini CLI
#     danger-guard-cursor.py  Cursor
#     danger-guard-agy.py     agy(Antigravity CLI)
#   Gemini CLI 和 agy 共用 ~/.gemini/hooks 目录,自动找会撞车 —— 那里请显式传入口名:
#     danger-guard-canary.sh danger-guard-agy.py
#   各家输出协议也不同,日志里的 decision 字段会按各自键名取:
#     hookSpecificOutput.permissionDecision / decision / permission
#
# 看证据: cat <本脚本同目录>/guard-canary.log
# 移除:   rm 本脚本和 guard-canary.log,再重跑对应的 install-*.sh(hook 命令会改回直连 python)
#
# ⚠ fail-open:本脚本挂掉时命令会照常执行、只是没有守卫,所以别长期挂着。

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PY=/usr/bin/python3
LOG="$DIR/guard-canary.log"

GUARD=""
if [ -n "${1:-}" ] && [ -f "$DIR/$1" ]; then
  GUARD="$DIR/$1"
else
  for g in danger-guard.py danger-guard-gemini.py danger-guard-cursor.py danger-guard-agy.py; do
    if [ -f "$DIR/$g" ]; then GUARD="$DIR/$g"; break; fi
  done
fi
if [ -z "$GUARD" ]; then
  printf '%s\t%s\t%s\n' "$(date '+%F %T')" "no-guard" "同目录没找到守卫入口,放行" >> "$LOG"
  exit 0
fi

input=$(cat)
out=$(printf '%s' "$input" | "$PY" "$GUARD" 2>/dev/null)

# 命令文本:Claude 系在 tool_input.command,Cursor 在顶层 command,agy 在 toolCall.args.CommandLine
cmd=$(printf '%s' "$input" | "$PY" -c 'import sys,json;d=json.load(sys.stdin);print((d.get("command") or (d.get("tool_input") or {}).get("command") or ((d.get("toolCall") or {}).get("args") or {}).get("CommandLine") or "")[:200])' 2>/dev/null)
# 判定:没输出=放行;有输出则按各家键名取
dec=$(printf '%s' "$out" | "$PY" -c 'import sys,json;d=sys.stdin.read().strip()
if not d: print("allow(放行)")
else:
    o=json.loads(d)
    print(o.get("hookSpecificOutput",{}).get("permissionDecision") or o.get("decision") or o.get("permission") or "?")' 2>/dev/null)

printf '%s\t%s\t%s\n' "$(date '+%F %T')" "${dec:-?}" "$cmd" >> "$LOG"

if [ -n "$out" ]; then
  printf '%s\n' "$out"
fi
exit 0
