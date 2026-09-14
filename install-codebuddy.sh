#!/usr/bin/env bash
# CodeBuddy Code 命令守卫 — 安装脚本 (macOS)
#
# CodeBuddy 的 hook 协议与 Claude Code 完全一致:同样读 hookSpecificOutput
# .permissionDecision 的 deny/ask,事件名同为 PreToolUse,输入 JSON 同构
# (hook_event_name / tool_name / tool_input)。所以直接复用 danger-guard.py,
# 判定引擎 core.py 与规则库 rules.py 也是同一份。
#
# 用法:
#   bash install-codebuddy.sh
set -euo pipefail

CB_DIR="${CODEBUDDY_HOME:-${HOME}/.codebuddy}"
HOOKS_DIR="${CB_DIR}/hooks"
SETTINGS="${CB_DIR}/settings.json"
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

echo "[2/3] 合并 PreToolUse hook + 设 bypass 权限模式 -> ${SETTINGS}"
/usr/bin/python3 - "$SETTINGS" "$SCRIPT_DST" "$SRC_DIR" <<'PY'
import json, os, sys

settings_path, script_dst, src_dir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, src_dir)
import rules

if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as f:
        data = json.load(f)
    bak = settings_path + ".bak.cmdguard"
    with open(bak, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("      已备份原配置 ->", bak)
else:
    data = {}

entry = {
    "matcher": "Bash",
    "hooks": [
        {"type": "command", "command": "/usr/bin/python3 %s" % script_dst, "timeout": 60}
    ],
}

hooks = data.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])


def points_to_guard(e):
    return any("danger-guard.py" in h.get("command", "") for h in e.get("hooks", []))


pre[:] = [e for e in pre if not points_to_guard(e)]
pre.insert(0, entry)          # 放最前,保证先于其它 hook 判定
print("      已写入 PreToolUse hook")

perm = data.setdefault("permissions", {})
perm["defaultMode"] = "bypassPermissions"

old = list(perm.get("deny") or [])
kept = [x for x in old if x not in rules.CLAUDE_DENY_OVERBROAD]
removed = [x for x in old if x in rules.CLAUDE_DENY_OVERBROAD]
for x in rules.CLAUDE_DENY:
    if x not in kept:
        kept.append(x)
perm["deny"] = kept
print("      推荐 deny:", kept)
if removed:
    print("      已移除过宽 deny:", removed)

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

echo "[3/3] 完成 ✅"
echo
echo "请重启 CodeBuddy(新会话生效)。"
echo "验证钩子:"
echo "  echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | /usr/bin/python3 ${SCRIPT_DST}"
echo
echo "注意:CodeBuddy 的 -y / bypassPermissions 下 HIGH/CRITICAL 级命令仍会问一次,"
echo "      这是客户端自身的高危审批,守卫管不到(见 README)。"
