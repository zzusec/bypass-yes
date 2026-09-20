#!/usr/bin/env bash
# Crush 命令守卫 — 安装脚本 (macOS)
#
# ⚠ 未端到端验证:本机没装 Crush,以下按官方 crush-config 技能文档实现(输入/输出/配置形状
#    都对得上文档),但「钩子有没有真被调用」没实测过。装完请拿 danger-guard-canary.sh
#    取证一次(README 里有步骤),确认日志里真有记录再当它生效。
#
# Crush 的拦截点是 crush.json 的 hooks.PreToolUse(目前只支持这一个事件):
#   输入  { event, session_id, cwd, tool_name: "bash", tool_input: { command } }  与 Claude 系同构
#   输出  { decision: "allow"|"deny"|"none", reason }  —— 没有 ask;exit 2 也算拦截
# 判定引擎 core.py 与规则库 rules.py 与其它各家同一份真源,入口是 danger-guard-crush.py。
#
# 落点:$XDG_CONFIG_HOME/crush/crush.json(默认 ~/.config/crush/crush.json)。
# Crush 还有个 crushrc(Bash 格式)会和 crush.json 深合并、冲突时 crushrc 赢 —— 如果你用
# crushrc 且在里面写过 PreToolUse,请自己确认不会盖掉这条。
#
# 免确认模式:Crush 的是 `crush --yolo` 或 options.skip_permission_requests,本脚本不碰它。
# 守卫独立生效:yolo 下 WARN 一样硬拒(因为 Crush 没有 ask 可用)。
#
# 用法:
#   bash install-crush.sh
set -euo pipefail

CRUSH_DIR="${CRUSH_HOME:-${XDG_CONFIG_HOME:-${HOME}/.config}/crush}"
HOOKS_DIR="${CRUSH_DIR}/hooks"
CONFIG="${CRUSH_DIR}/crush.json"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DST="${HOOKS_DIR}/danger-guard-crush.py"

echo "[1/3] 复制脚本、规则库与铃声 -> ${HOOKS_DIR}"
mkdir -p "${HOOKS_DIR}"
cp "${SRC_DIR}/danger-guard-crush.py" "${SCRIPT_DST}"
cp "${SRC_DIR}/core.py" "${SRC_DIR}/rules.py" "${HOOKS_DIR}/"
if [ -f "${SRC_DIR}/chime.wav" ]; then
  cp "${SRC_DIR}/chime.wav" "${HOOKS_DIR}/chime.wav"
else
  echo "      警告: 仓库内缺少 chime.wav,危险命令将静音"
fi

echo "[2/3] 合并 hooks.PreToolUse -> ${CONFIG}"
/usr/bin/python3 - "$CONFIG" "$SCRIPT_DST" <<'PY'
import json, os, sys

config_path, script_dst = sys.argv[1], sys.argv[2]

if os.path.exists(config_path):
    with open(config_path, encoding="utf-8") as f:
        data = json.load(f)
    bak = config_path + ".bak.cmdguard"
    with open(bak, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("      已备份原配置 ->", bak)
else:
    data = {}

if not isinstance(data, dict):
    data = {}

hooks = data.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])
if not isinstance(pre, list):
    pre = []
    hooks["PreToolUse"] = pre

# 按 name 去重即幂等,别人的钩子原样保留
pre[:] = [e for e in pre if not (isinstance(e, dict) and e.get("name") == "bypass-yes")]
pre.insert(0, {
    "name": "bypass-yes",
    "matcher": "^bash$",          # matcher 是正则,只挂 shell 工具
    "command": "/usr/bin/python3 %s" % script_dst,
    "timeout": 10,
})
print("      已写入 hooks.PreToolUse(name=bypass-yes)")

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

echo "[3/3] 完成 ✅"
echo
echo "验证钩子(应输出 decision: deny):"
echo "  echo '{\"tool_name\":\"bash\",\"tool_input\":{\"command\":\"rm -rf /\"},\"cwd\":\"/tmp\"}' | /usr/bin/python3 ${SCRIPT_DST}"
echo
echo "说明:Crush 没有 ask 这一档,所以 WARN(git reset --hard 等)和 BLOCK 一样硬拒;"
echo "      想放行某类命令就写进 ~/.claude/hooks/allowlist.txt(各家共享)。"
echo "      本机没装 Crush,这套没端到端验证过 —— 请用 danger-guard-canary.sh 取证一次。"
