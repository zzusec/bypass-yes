#!/usr/bin/env bash
# agy(Antigravity CLI)命令守卫 — 安装脚本 (macOS)
#
# agy 的拦截点是 hooks.json 的 PreToolUse 事件:
#   输入  { toolCall: { name: "run_command", args: { CommandLine, Cwd } }, workspacePaths, ... }
#   输出  { decision: "deny"|"ask"|"force_ask"|"allow", reason };空 stdout = 放行
# 判定引擎 core.py 与规则库 rules.py 与其它各家同一份真源,入口是 danger-guard-agy.py。
#
# 落点是 ~/.gemini/config/hooks.json,不是 ~/.gemini/hooks.json —— 后者 /hooks 里也列得出来、
# 日志里也写 loaded,但实测根本不会执行(是 TUI 与后端共用的那份 config/hooks.json 才生效)。
# 项目级则是 <仓库>/.agents/hooks.json。
#
# hooks.json 的顶层键是「钩子名」(可以有多个,来自不同插件/配置,同事件会合并按序执行),
# 所以本脚本只写自己那一个键 bypass-yes,不动别人的。
#
# 免确认模式:agy 的 turbo 只能命令行给(`agy --dangerously-skip-permissions`),
# settings.json 里那个 permissionPreset 是 UI 状态、值域没有公开文档,本脚本不碰权限模式。
# 想常开就自己加 alias:
#   alias agy='agy --dangerously-skip-permissions'
# 注意 turbo 会吞掉确认框,那时请连同 export DANGER_GUARD_BYPASS=1 一起(WARN 升硬拒)。
#
# 用法:
#   bash install-agy.sh
set -euo pipefail

AGY_DIR="${AGY_HOME:-${HOME}/.gemini}"
HOOKS_DIR="${AGY_DIR}/hooks"
HOOKS_JSON="${AGY_DIR}/config/hooks.json"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DST="${HOOKS_DIR}/danger-guard-agy.py"

echo "[1/3] 复制脚本、规则库与铃声 -> ${HOOKS_DIR}"
mkdir -p "${HOOKS_DIR}"
cp "${SRC_DIR}/danger-guard-agy.py" "${SCRIPT_DST}"
cp "${SRC_DIR}/core.py" "${SRC_DIR}/rules.py" "${HOOKS_DIR}/"
if [ -f "${SRC_DIR}/chime.wav" ]; then
  cp "${SRC_DIR}/chime.wav" "${HOOKS_DIR}/chime.wav"
else
  echo "      警告: 仓库内缺少 chime.wav,危险命令将静音"
fi

echo "[2/3] 合并 PreToolUse hook -> ${HOOKS_JSON}"
mkdir -p "$(dirname "${HOOKS_JSON}")"
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

# 顶层键 = 钩子名;整键覆盖即幂等,别人的钩子原样保留
data["bypass-yes"] = {
    "PreToolUse": [{
        "matcher": "run_command",
        "hooks": [{
            "type": "command",
            "command": "/usr/bin/python3 %s" % script_dst,
            "timeout": 10,
        }],
    }],
}
print("      已写入 PreToolUse hook(钩子名 bypass-yes)")

with open(hooks_json, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

echo "[3/3] 完成 ✅"
echo
echo "验证钩子(应输出 decision: deny):"
echo "  echo '{\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"rm -rf /\"}}}' | /usr/bin/python3 ${SCRIPT_DST}"
echo
echo "说明:agy 认 force_ask,所以 WARN 档(git reset --hard 等)每次都弹确认框(不吃"
echo "      Always Allow 缓存)。若你开 turbo(--dangerously-skip-permissions),确认框会被"
echo "      吞掉,启动前 export DANGER_GUARD_BYPASS=1 把 WARN 升成硬拒;想放行某类命令"
echo "      就写进 ~/.claude/hooks/allowlist.txt。"
