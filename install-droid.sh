#!/usr/bin/env bash
# Factory droid 命令守卫 — 安装脚本 (macOS)
#
# ⚠ 未端到端验证:本机没装 droid,以下按 Factory 官方 hooks 文档实现(协议与 Claude Code
#    完全一致,文档明说脚本可直接沿用),但「钩子有没有真被调用」没实测过。装完请拿
#    danger-guard-canary.sh 取证一次(README 里有步骤),确认日志里真有记录再当它生效。
#
# droid 的拦截点是 ~/.factory/hooks.json 的 PreToolUse,协议与 Claude Code 同构:
#   输入  { session_id, cwd, permission_mode, hook_event_name, tool_name, tool_input }
#   输出  { hookSpecificOutput: { hookEventName, permissionDecision, permissionDecisionReason } }
# 差别只有两处:shell 工具叫 Execute(不是 Bash),payload 直接带 permission_mode
# (off / spec / auto-low / auto-medium / auto-high)—— 所以入口直接复用 danger-guard.py。
#
# 注意 droid 早期把 hooks 写在 hooks/hooks.json,新版改成 scope 根下的 hooks.json;
# 本脚本只写新位置。老文件如果还在,droid 会在下次保存时归档成 hooks.migrated.json。
#
# 免确认模式:droid 的是 permission_mode = auto-*,由它自己的设置/命令行决定,本脚本不碰。
# auto-* 下 ask 弹不出来,守卫会把 WARN 升成硬拒(见 danger-guard.py)。
#
# 用法:
#   bash install-droid.sh
set -euo pipefail

FACTORY_DIR="${FACTORY_HOME:-${HOME}/.factory}"
HOOKS_DIR="${FACTORY_DIR}/hooks"
HOOKS_JSON="${FACTORY_DIR}/hooks.json"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DST="${HOOKS_DIR}/danger-guard.py"

echo "[1/3] 复制脚本、规则库与铃声 -> ${HOOKS_DIR}"
mkdir -p "${HOOKS_DIR}"
cp "${SRC_DIR}/danger-guard.py" "${SCRIPT_DST}"
cp "${SRC_DIR}/core.py" "${SRC_DIR}/rules.py" "${HOOKS_DIR}/"
if [ -f "${SRC_DIR}/chime.wav" ]; then
  cp "${SRC_DIR}/chime.wav" "${HOOKS_DIR}/chime.wav"
else
  echo "      警告: 仓库内缺少 chime.wav,危险命令将静音"
fi

echo "[2/3] 合并 PreToolUse hook -> ${HOOKS_JSON}"
/usr/bin/python3 - "$HOOKS_JSON" "$SCRIPT_DST" <<'PY'
import json, os, sys

hooks_json, script_dst = sys.argv[1], sys.argv[2]

if os.path.exists(hooks_json):
    with open(hooks_json, encoding="utf-8") as f:
        data = json.load(f)
    bak = hooks_json + ".bak.cmdguard"
    with open(bak, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("      已备份原配置 ->", bak)
else:
    data = {}

if not isinstance(data, dict):
    data = {}

# hooks.json 的根就是事件表(没有再套一层 "hooks")
pre = data.setdefault("PreToolUse", [])
if not isinstance(pre, list):
    pre = []
    data["PreToolUse"] = pre

command = "/usr/bin/python3 %s" % script_dst


def is_ours(entry):
    if not isinstance(entry, dict):
        return False
    return any("danger-guard.py" in (h or {}).get("command", "")
               for h in entry.get("hooks", []) if isinstance(h, dict))


pre[:] = [e for e in pre if not is_ours(e)]
pre.insert(0, {
    "matcher": "Execute",        # droid 的 shell 工具名
    "hooks": [{"type": "command", "command": command, "timeout": 10}],
})
print("      已写入 PreToolUse hook(matcher=Execute)")

with open(hooks_json, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

echo "[3/3] 完成 ✅"
echo
echo "验证钩子(应输出 permissionDecision: deny):"
echo "  echo '{\"tool_name\":\"Execute\",\"tool_input\":{\"command\":\"rm -rf /\"},\"cwd\":\"/tmp\"}' | /usr/bin/python3 ${SCRIPT_DST}"
echo
echo "说明:droid 认 ask,所以非 auto 模式下 WARN(git reset --hard 等)会弹确认框;"
echo "      permission_mode 是 auto-* 时 ask 弹不出来,守卫自动把 WARN 升成硬拒。"
echo "      想放行某类命令就写进 ~/.claude/hooks/allowlist.txt(各家共享)。"
echo "      本机没装 droid,这套没端到端验证过 —— 请用 danger-guard-canary.sh 取证一次。"
