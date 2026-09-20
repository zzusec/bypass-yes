#!/usr/bin/env bash
# 五家一起装:Claude Code + Codex CLI + CodeBuddy Code + zcode + pi
#
# 等价于依次跑 install.sh --bypass / install-codex.sh / install-codebuddy.sh /
# install-zcode.sh / install-pi.sh,只是不用敲五遍。各脚本都是幂等的,重复跑只会刷新到最新。
#
# 用法:
#   bash install-all.sh               # 五家都装,Claude/CodeBuddy/zcode 用免确认(bypass/yolo)模式
#   bash install-all.sh --no-bypass   # 只装守卫,不动权限模式(pi 无权限模式,始终装守卫)
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

echo "===== 1/5 Claude Code ====="
bash "${SRC_DIR}/install.sh" "$ARG"
echo
echo "===== 2/5 Codex CLI ====="
bash "${SRC_DIR}/install-codex.sh"
echo
echo "===== 3/5 CodeBuddy Code ====="
bash "${SRC_DIR}/install-codebuddy.sh" "$ARG"
echo
echo "===== 4/5 zcode ====="
bash "${SRC_DIR}/install-zcode.sh" "$ARG"
echo
echo "===== 5/5 pi ====="
bash "${SRC_DIR}/install-pi.sh"
echo
echo "五家都装好了。"
echo
echo "接下来:"
echo "  1) 重启 Claude Code / CodeBuddy / zcode(权限模式改动要重启才生效);pi 里 /reload 或重启"
echo "  2) Codex 还要在会话里执行 /hooks,把 PreToolUse、PermissionRequest"
echo "     两条 danger-guard Trust 一次 —— 没 Trust 时钩子会静默不执行"
