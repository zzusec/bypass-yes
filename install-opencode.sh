#!/usr/bin/env bash
# opencode 命令守卫 — 安装脚本 (macOS)
#
# opencode 没有命令行 hook,拦截点是插件的 tool.execute.before:
#   输入  input { tool, sessionID, callID } / output { args }   shell 工具名是 "bash",命令在 output.args.command
#   结果  throw 一个 Error = 拦下这条命令(错误原文回给模型并显示在终端);不抛 = 放行
# 插件是 JS,不方便内嵌整套规则,所以由它调用 hooks/danger-guard-pi.py(通用桥接,
# pi 和 opencode 共用)拿分级,判定引擎 core.py 与规则库 rules.py 仍是各家同一份真源。
#
# 落点:
#   ~/.config/opencode/plugin/bypass-yes-opencode.js   全局自动发现(plugins 复数目录也能加载,本项目用单数)
#   ~/.config/opencode/hooks/                          桥接脚本 + core.py + rules.py + 铃声
#
# 免确认模式:opencode 的是 `opencode run --auto`(或 TUI 里的 auto),没有配置文件开关,
# 本脚本不碰权限设置。守卫独立于 auto 生效 —— 插件抛错在 auto 下照样拦得住。
#
# 用法:
#   bash install-opencode.sh
set -euo pipefail

OC_DIR="${OPENCODE_HOME:-${XDG_CONFIG_HOME:-${HOME}/.config}/opencode}"
PLUGIN_DIR="${OC_DIR}/plugin"
HOOKS_DIR="${OC_DIR}/hooks"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[1/3] 复制桥接脚本、规则库与铃声 -> ${HOOKS_DIR}"
mkdir -p "${HOOKS_DIR}"
cp "${SRC_DIR}/danger-guard-pi.py" "${SRC_DIR}/core.py" "${SRC_DIR}/rules.py" "${HOOKS_DIR}/"
if [ -f "${SRC_DIR}/chime.wav" ]; then
  cp "${SRC_DIR}/chime.wav" "${HOOKS_DIR}/chime.wav"
else
  echo "      警告: 仓库内缺少 chime.wav,危险命令将静音"
fi

echo "[2/3] 复制插件 -> ${PLUGIN_DIR}/bypass-yes-opencode.js"
mkdir -p "${PLUGIN_DIR}"
cp "${SRC_DIR}/bypass-yes-opencode.js" "${PLUGIN_DIR}/bypass-yes-opencode.js"

echo "[3/3] 完成 ✅"
echo
echo "验证桥接(应输出 level: block):"
echo "  /usr/bin/python3 ${HOOKS_DIR}/danger-guard-pi.py '{\"command\":\"rm -rf /\",\"cwd\":\"/tmp\"}'"
echo
echo "说明:插件在下次启动 opencode 时加载。opencode 这层没有「确认框」可用,所以 WARN 档"
echo "      (git reset --hard 等)和 BLOCK 一样硬拒;想放行某类命令就写进"
echo "      ~/.claude/hooks/allowlist.txt(各家共享)。"
