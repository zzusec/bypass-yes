#!/usr/bin/env bash
# GitHub Copilot CLI 命令守卫 — 安装脚本 (macOS)
#
# ⚠ 未端到端验证:本机没装 copilot,以下按官方 hooks reference 实现(事件名/payload/输出字段
#    /配置落点都对得上文档),但「钩子有没有真被调用」没实测过。装完请拿
#    danger-guard-canary.sh 取证一次(README 里有步骤),确认日志里真有记录再当它生效。
#
# Copilot CLI 的拦截点是用户级 hooks 目录里的 *.json,事件用 PascalCase 的 PreToolUse:
#   输入  { hook_event_name, session_id, cwd, tool_name: "Bash", tool_input }  与 Claude 同构
#   输出  { permissionDecision: "allow"|"deny"|"ask", permissionDecisionReason }  平铺,没有 hookSpecificOutput
# 判定引擎 core.py 与规则库 rules.py 与其它各家同一份真源,入口是 danger-guard-copilot.py。
#
# 为什么用 PascalCase 而不是 camelCase 的 preToolUse:PascalCase 走 VS Code 兼容格式,
# payload 字段名和工具名(Bash)都与 Claude 一致,core.get_command / core.TOOL_NAMES 直接能用。
#
# 落点:~/.copilot/hooks/(COPILOT_HOME 设了就是 $COPILOT_HOME/hooks/)。
# Copilot 只把这个目录里的 *.json 当钩子配置读,同目录的 .py 不会被它碰。
#
# ⚠ Copilot 对 preToolUse 命令钩子是 fail-closed:钩子崩溃或非 0 退出会**拒掉**命令(不是放行)。
#    danger-guard-copilot.py 为此把 import 都包在 try 里,任何异常都 exit 0。别改成会抛异常的写法。
#
# 免确认模式:Copilot 的是 `--allow-all-tools`,没有配置文件开关,本脚本不碰权限设置。
# 那种模式下 hook 的 ask 可能弹不出来,启动前 export DANGER_GUARD_BYPASS=1 把 WARN 升硬拒。
#
# 用法:
#   bash install-copilot.sh
set -euo pipefail

COPILOT_DIR="${COPILOT_HOME:-${HOME}/.copilot}"
HOOKS_DIR="${COPILOT_DIR}/hooks"
HOOKS_JSON="${HOOKS_DIR}/bypass-yes.json"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DST="${HOOKS_DIR}/danger-guard-copilot.py"

echo "[1/3] 复制脚本、规则库与铃声 -> ${HOOKS_DIR}"
mkdir -p "${HOOKS_DIR}"
cp "${SRC_DIR}/danger-guard-copilot.py" "${SCRIPT_DST}"
cp "${SRC_DIR}/core.py" "${SRC_DIR}/rules.py" "${HOOKS_DIR}/"
if [ -f "${SRC_DIR}/chime.wav" ]; then
  cp "${SRC_DIR}/chime.wav" "${HOOKS_DIR}/chime.wav"
else
  echo "      警告: 仓库内缺少 chime.wav,危险命令将静音"
fi

echo "[2/3] 写入 PreToolUse hook -> ${HOOKS_JSON}"
/usr/bin/python3 - "$HOOKS_JSON" "$SCRIPT_DST" <<'PY'
import json, os, sys

hooks_json, script_dst = sys.argv[1], sys.argv[2]

if os.path.exists(hooks_json):
    bak = hooks_json + ".bak.cmdguard"
    with open(hooks_json, encoding="utf-8") as f:
        old = f.read()
    with open(bak, "w", encoding="utf-8") as f:
        f.write(old)
    print("      已备份原配置 ->", bak)

# 独立文件,整份覆盖即幂等 —— 目录里别人的 *.json 各自独立加载,不受影响。
# exec + args 直接起可执行文件,不过 shell:路径里有空格也不会被拆开。
data = {
    "version": 1,
    "hooks": {
        "PreToolUse": [{
            "type": "command",
            "matcher": "Bash",          # PascalCase 下用 Claude 工具名
            "exec": "/usr/bin/python3",
            "args": [script_dst],
            "timeoutSec": 10,
        }],
    },
}

with open(hooks_json, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print("      已写入 PreToolUse hook(matcher=Bash)")
PY

echo "[3/3] 完成 ✅"
echo
echo "验证钩子(应输出 permissionDecision: deny):"
echo "  echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"},\"cwd\":\"/tmp\"}' | /usr/bin/python3 ${SCRIPT_DST}"
echo
echo "说明:Copilot 认 ask,所以 WARN(git reset --hard 等)会弹确认框。若你用"
echo "      --allow-all-tools(确认框可能被吞),启动前 export DANGER_GUARD_BYPASS=1,"
echo "      守卫会把 WARN 升成硬拒;想放行某类命令就写进 ~/.claude/hooks/allowlist.txt。"
echo "      本机没装 copilot,这套没端到端验证过 —— 请用 danger-guard-canary.sh 取证一次。"
