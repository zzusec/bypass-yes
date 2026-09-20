#!/usr/bin/env bash
# 九家一起装:Claude Code + Codex CLI + CodeBuddy + zcode + pi + Qoder + Gemini CLI + Cursor + agy
#
# 等价于依次跑各个 install-*.sh,只是不用敲九遍。各脚本都是幂等的,重复跑只会刷新到最新。
#
# 用法:
#   bash install-all.sh               # 九家都装,能设免确认的都设上(bypass/yolo)
#   bash install-all.sh --no-bypass   # 只装守卫,不动权限模式
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:---bypass}"

case "$ARG" in
  --bypass|--no-bypass) ;;
  *)
    echo "用法: bash install-all.sh [--bypass|--no-bypass]" >&2
    exit 1
    ;;
esac

echo "===== 1/9 Claude Code ====="
bash "${SRC_DIR}/install.sh" "$ARG"
echo
echo "===== 2/9 Codex CLI ====="
bash "${SRC_DIR}/install-codex.sh"
echo
echo "===== 3/9 CodeBuddy Code ====="
bash "${SRC_DIR}/install-codebuddy.sh" "$ARG"
echo
echo "===== 4/9 zcode ====="
bash "${SRC_DIR}/install-zcode.sh" "$ARG"
echo
echo "===== 5/9 pi ====="
bash "${SRC_DIR}/install-pi.sh"
echo
echo "===== 6/9 Qoder CLI ====="
bash "${SRC_DIR}/install-qoder.sh" "$ARG"
echo
echo "===== 7/9 Gemini CLI ====="
bash "${SRC_DIR}/install-gemini.sh"
echo
echo "===== 8/9 Cursor ====="
bash "${SRC_DIR}/install-cursor.sh"
echo
echo "===== 9/9 agy(Antigravity CLI)====="
bash "${SRC_DIR}/install-agy.sh"
echo
echo "九家都装好了。"
echo
echo "接下来:"
echo "  1) 重启客户端(权限模式改动要重启才生效);pi 在会话里 /reload 热加载即可"
echo "  2) Codex 还要在会话里执行 /hooks,把 PreToolUse、PermissionRequest"
echo "     两条 danger-guard Trust 一次 —— 没 Trust 时钩子会静默不执行"
echo "  3) Gemini CLI 的 yolo 只能在命令行给:gemini --yolo(settings.json 里配不了)"
echo "  4) agy 的 turbo 同理只能命令行给:agy --dangerously-skip-permissions"
