#!/usr/bin/env bash
# Gemini CLI 命令守卫 — 安装脚本 (macOS)
#
# Gemini CLI 的拦截点是 settings.json 里的 hooks.BeforeTool 事件:
#   输入  { hook_event_name, tool_name, tool_input, cwd, ... }  (shell 工具叫 run_shell_command)
#   输出  { decision: "deny", reason, systemMessage }            (只有 allow/deny,没有 ask)
# 判定引擎 core.py 与规则库 rules.py 与其它各家同一份真源,入口是 danger-guard-gemini.py。
#
# 免确认模式:settings.json 里没有 yolo 这一档 —— general.defaultApprovalMode 只接受
# default / auto_edit / plan,yolo 必须走命令行(--yolo 或 --approval-mode=yolo)。
# 所以本脚本不碰权限模式,装完自己加 alias 即可:
#   alias gemini='gemini --yolo'
#
# 用法:
#   bash install-gemini.sh
set -euo pipefail

GEMINI_DIR="${GEMINI_HOME:-${HOME}/.gemini}"
HOOKS_DIR="${GEMINI_DIR}/hooks"
SETTINGS="${GEMINI_DIR}/settings.json"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DST="${HOOKS_DIR}/danger-guard-gemini.py"

echo "[1/3] 复制脚本、规则库与铃声 -> ${HOOKS_DIR}"
mkdir -p "${HOOKS_DIR}"
cp "${SRC_DIR}/danger-guard-gemini.py" "${SCRIPT_DST}"
cp "${SRC_DIR}/core.py" "${SRC_DIR}/rules.py" "${HOOKS_DIR}/"
if [ -f "${SRC_DIR}/chime.wav" ]; then
  cp "${SRC_DIR}/chime.wav" "${HOOKS_DIR}/chime.wav"
else
  echo "      警告: 仓库内缺少 chime.wav,危险命令将静音"
fi

echo "[2/3] 合并 BeforeTool hook -> ${SETTINGS}"
if [ ! -f "${SETTINGS}" ]; then
  echo "      提示: ${SETTINGS} 不存在(没跑过 gemini?),将新建一个最小配置。"
fi
/usr/bin/python3 - "$SETTINGS" "$SCRIPT_DST" <<'PY'
import json, os, sys

settings_path, script_dst = sys.argv[1], sys.argv[2]

if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as f:
        data = json.load(f)
    bak = settings_path + ".bak.cmdguard"
    with open(bak, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("      已备份原配置 ->", bak)
else:
    data = {}

# ---- hooks.BeforeTool ----
hooks = data.setdefault("hooks", {})
before = hooks.setdefault("BeforeTool", [])
if not isinstance(before, list):
    before = []
    hooks["BeforeTool"] = before

# 只挂在 shell 工具上:读文件/搜索之类不必每次都过一遍守卫
entry = {
    "matcher": "run_shell_command",
    "hooks": [
        {
            "type": "command",
            "command": "/usr/bin/python3 %s" % script_dst,
            "name": "danger-guard",
            "timeout": 60000,     # Gemini 的 timeout 单位是毫秒
        }
    ],
}


def points_to_guard(e):
    return any("danger-guard-gemini.py" in h.get("command", "") for h in (e.get("hooks") or []))


before[:] = [e for e in before if isinstance(e, dict) and not points_to_guard(e)]
before.insert(0, entry)
print("      已写入 BeforeTool hook(matcher=run_shell_command)")

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

echo "[3/3] 完成 ✅"
echo
echo "验证钩子(应输出 decision: deny):"
echo "  echo '{\"tool_name\":\"run_shell_command\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | /usr/bin/python3 ${SCRIPT_DST}"
echo
echo "注意两件事:"
echo "  1) Gemini 的 hook 只有 allow/deny、没有 ask,所以 WARN 档(git reset --hard 等)"
echo "     一律硬拒 —— 想放行某类命令就写进 ~/.claude/hooks/allowlist.txt(各家共享)。"
echo "  2) 免确认(yolo)settings.json 里配不了,要自己带参数:gemini --yolo"
