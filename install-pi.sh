#!/usr/bin/env bash
# pi 命令守卫 — 安装脚本 (macOS)
#
# pi(@earendil-works/pi-coding-agent)没有 Claude 那种命令行 hook,也没有沙箱、默认不审批
# 任何命令(等价于一直 yolo)。它的拦截点是 TypeScript 扩展的 tool_call 事件。所以这里装两样:
#
#   1) ~/.pi/agent/hooks/         桥接脚本 danger-guard-pi.py + 引擎 core.py + 规则 rules.py + 铃声
#   2) ~/.pi/agent/extensions/    扩展 bypass-yes-guard.ts(全局自动发现)
#
# 扩展在 bash 工具执行前调用桥接脚本(判定逻辑/规则和其它四家同一份真源),拿回分级:
#   block → 硬拦截;warn → 弹真确认框 ctx.ui.confirm(无 UI 的 headless 模式保守硬拦);safe → 放行。
#
# pi 的扩展靠目录自动发现,不需要改 settings.json。装完在 pi 里 /reload 热加载,或重启 pi。
#
# 用法:
#   bash install-pi.sh
set -euo pipefail

PI_DIR="${PI_HOME:-${HOME}/.pi/agent}"
HOOKS_DIR="${PI_DIR}/hooks"
EXT_DIR="${PI_DIR}/extensions"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_DST="${HOOKS_DIR}/danger-guard-pi.py"
EXT_DST="${EXT_DIR}/bypass-yes-guard.ts"

echo "[1/3] 复制桥接脚本、引擎、规则库与铃声 -> ${HOOKS_DIR}"
mkdir -p "${HOOKS_DIR}" "${EXT_DIR}"
cp "${SRC_DIR}/danger-guard-pi.py" "${BRIDGE_DST}"
chmod +x "${BRIDGE_DST}"
cp "${SRC_DIR}/core.py" "${SRC_DIR}/rules.py" "${HOOKS_DIR}/"
if [ -f "${SRC_DIR}/chime.wav" ]; then
  cp "${SRC_DIR}/chime.wav" "${HOOKS_DIR}/chime.wav"
else
  echo "      警告: 仓库内缺少 chime.wav,危险命令将静音"
fi

echo "[2/3] 安装扩展 -> ${EXT_DST}"
if [ -f "${EXT_DST}" ]; then
  cp "${EXT_DST}" "${EXT_DST}.bak.cmdguard"
  echo "      已备份原扩展 -> ${EXT_DST}.bak.cmdguard"
fi
cp "${SRC_DIR}/bypass-yes-guard.ts" "${EXT_DST}"

# 解释器自检:扩展默认用 /usr/bin/python3 调桥接脚本
if [ ! -x /usr/bin/python3 ]; then
  echo "      警告: 没找到 /usr/bin/python3。请装 Xcode 命令行工具,或在启动 pi 前"
  echo "            export DANGER_GUARD_PY=\$(command -v python3) 指定解释器。"
fi

echo "[3/3] 完成 ✅"
echo
echo "请在 pi 会话里执行 /reload 热加载扩展(或重启 pi)。"
echo "验证桥接脚本(应输出 {\"level\": \"block\", ...}):"
echo "  /usr/bin/python3 ${BRIDGE_DST} '{\"command\":\"rm -rf /\",\"cwd\":\"/tmp\"}'"
echo
echo "说明:pi 没有沙箱、默认不审批命令,这层守卫就是给它补上「别出事」。"
echo "      warn 级会弹确认框;headless(pi -p / --mode json)下弹不了框则保守硬拦。"
echo "      想放行某类命令就写进 ~/.claude/hooks/allowlist.txt(九家共享)。"
