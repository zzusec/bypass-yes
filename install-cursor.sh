#!/usr/bin/env bash
# Cursor 命令守卫 — 安装脚本 (macOS)
#
# Cursor 的拦截点不是 settings.json,而是独立的 hooks.json(用户级 ~/.cursor/hooks.json,
# 项目级 <仓库>/.cursor/hooks.json),事件名叫 beforeShellExecution:
#   输入  { hook_event_name, command, cwd, workspace_roots }  命令文本在顶层 command
#   输出  { permission: "deny"|"allow"|"ask", userMessage, agentMessage }
# 判定引擎 core.py 与规则库 rules.py 与其它各家同一份真源,入口是 danger-guard-cursor.py。
#
# hooks.json 必须有顶层 "version": 1,且每个事件是 {command} 对象的数组 —— 格式不对
# 会直接 Failed to parse hooks configuration。
#
# 用法:
#   bash install-cursor.sh
set -euo pipefail

CURSOR_DIR="${CURSOR_HOME:-${HOME}/.cursor}"
HOOKS_DIR="${CURSOR_DIR}/hooks"
HOOKS_JSON="${CURSOR_DIR}/hooks.json"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DST="${HOOKS_DIR}/danger-guard-cursor.py"

echo "[1/3] 复制脚本、规则库与铃声 -> ${HOOKS_DIR}"
mkdir -p "${HOOKS_DIR}"
cp "${SRC_DIR}/danger-guard-cursor.py" "${SCRIPT_DST}"
cp "${SRC_DIR}/core.py" "${SRC_DIR}/rules.py" "${HOOKS_DIR}/"
if [ -f "${SRC_DIR}/chime.wav" ]; then
  cp "${SRC_DIR}/chime.wav" "${HOOKS_DIR}/chime.wav"
else
  echo "      警告: 仓库内缺少 chime.wav,危险命令将静音"
fi

echo "[2/3] 合并 beforeShellExecution hook -> ${HOOKS_JSON}"
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

# version 是 Cursor 解析的硬要求,缺失会 Failed to parse
data["version"] = data.get("version", 1)

hooks = data.setdefault("hooks", {})
before = hooks.setdefault("beforeShellExecution", [])
if not isinstance(before, list):
    before = []
    hooks["beforeShellExecution"] = before

command = "/usr/bin/python3 %s" % script_dst
before[:] = [e for e in before if isinstance(e, dict) and "danger-guard-cursor.py" not in e.get("command", "")]
before.insert(0, {"command": command})
print("      已写入 beforeShellExecution hook")

with open(hooks_json, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

echo "[3/3] 完成 ✅"
echo
echo "验证钩子(应输出 permission: deny):"
echo "  echo '{\"command\":\"rm -rf /\",\"cwd\":\"/tmp\"}' | /usr/bin/python3 ${SCRIPT_DST}"
echo
echo "说明:Cursor 认 ask,所以 WARN 档(git reset --hard 等)会弹确认框。若你用的是"
echo "      自动执行/免确认模式(ask 会被吞),启动前 export DANGER_GUARD_BYPASS=1,"
echo "      守卫会把 WARN 升成硬拒;想放行某类命令就写进 ~/.claude/hooks/allowlist.txt。"
