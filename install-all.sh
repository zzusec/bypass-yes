#!/usr/bin/env bash
# 三家一起装:Claude Code + Codex CLI + CodeBuddy Code
#
# 等价于依次跑 install.sh --bypass / install-codex.sh / install-codebuddy.sh,
# 只是不用敲三遍。各脚本都是幂等的,重复跑只会刷新到最新。
#
# 用法:
#   bash install-all.sh               # 三家都装,Claude/CodeBuddy 用 bypass 模式
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

echo "===== 1/3 Claude Code ====="
bash "${SRC_DIR}/install.sh" "$ARG"
echo
echo "===== 2/3 Codex CLI ====="
bash "${SRC_DIR}/install-codex.sh"
echo
echo "===== 3/3 CodeBuddy Code ====="
bash "${SRC_DIR}/install-codebuddy.sh"
echo
echo "三家都装好了。"
echo
echo "接下来:"
echo "  1) 重启 Claude Code / CodeBuddy(权限模式改动要重启才生效)"
echo "  2) Codex 还要在会话里执行 /hooks,把 PreToolUse、PermissionRequest"
echo "     两条 danger-guard Trust 一次 —— 没 Trust 时钩子会静默不执行"
