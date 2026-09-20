#!/usr/bin/env bash
# Qoder CLI 命令守卫 — 安装脚本 (macOS)
#
# Qoder 是 Claude Code 的同构实现:hook 事件名同为 PreToolUse,输入 JSON 同构
# (hook_event_name / tool_name / tool_input.command / cwd),输出同样读
# hookSpecificOutput.permissionDecision 的 deny/ask,工具名同为 Bash。所以直接复用
# danger-guard.py,判定引擎 core.py 与规则库 rules.py 也是同一份真源。
#
# 与 Claude 的两点差别:
#   1) 免确认模式叫 general.defaultPermissionMode = "bypass_permissions"
#      (CLI 对等的 --permission-mode bypass_permissions / --dangerously-skip-permissions),
#      不是 permissions.defaultMode。dont_ask / yolo 同样属于"不弹确认",core 一并识别。
#   2) hook 直接挂在 settings.json 的 hooks.PreToolUse 下,没有 hooks.enabled 开关。
#
# 用法:
#   bash install-qoder.sh              # 装钩子并把权限模式设为 bypass_permissions(默认)
#   bash install-qoder.sh --no-bypass  # 只装钩子,不动权限模式(WARN 会弹确认框)
set -euo pipefail

QODER_DIR="${QODER_HOME:-${HOME}/.qoder}"
HOOKS_DIR="${QODER_DIR}/hooks"
SETTINGS="${QODER_DIR}/settings.json"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DST="${HOOKS_DIR}/danger-guard.py"

BYPASS_MODE="yes"
for arg in "$@"; do
  case "$arg" in
    --bypass|-y) BYPASS_MODE="yes" ;;
    --no-bypass) BYPASS_MODE="no" ;;
    *) echo "用法: bash install-qoder.sh [--bypass|--no-bypass]" >&2; exit 1 ;;
  esac
done

echo "[1/3] 复制脚本、规则库与铃声 -> ${HOOKS_DIR}"
mkdir -p "${HOOKS_DIR}"
cp "${SRC_DIR}/danger-guard.py" "${SCRIPT_DST}"
cp "${SRC_DIR}/core.py" "${SRC_DIR}/rules.py" "${HOOKS_DIR}/"
if [ -f "${SRC_DIR}/chime.wav" ]; then
  cp "${SRC_DIR}/chime.wav" "${HOOKS_DIR}/chime.wav"
else
  echo "      警告: 仓库内缺少 chime.wav,危险命令将静音"
fi

echo "[2/3] 合并 PreToolUse hook + 设权限模式 -> ${SETTINGS}"
if [ ! -f "${SETTINGS}" ]; then
  echo "      提示: ${SETTINGS} 不存在(没跑过 Qoder?),将新建一个最小配置。"
fi
/usr/bin/python3 - "$SETTINGS" "$SCRIPT_DST" "$BYPASS_MODE" <<'PY'
import json, os, sys

settings_path, script_dst, bypass_mode = sys.argv[1], sys.argv[2], sys.argv[3]

if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as f:
        data = json.load(f)
    bak = settings_path + ".bak.cmdguard"
    with open(bak, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("      已备份原配置 ->", bak)
else:
    data = {}

# ---- hooks.PreToolUse ----
hooks = data.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])
if not isinstance(pre, list):
    pre = []
    hooks["PreToolUse"] = pre

entry = {
    "matcher": "Bash",
    "hooks": [
        {"type": "command", "command": "/usr/bin/python3 %s" % script_dst, "timeout": 60}
    ],
}


def points_to_guard(e):
    return any("danger-guard.py" in h.get("command", "") for h in (e.get("hooks") or []))


# 去重后放最前,保证先于其它 hook 判定
pre[:] = [e for e in pre if isinstance(e, dict) and not points_to_guard(e)]
pre.insert(0, entry)
print("      已写入 PreToolUse hook(matcher=Bash)")

# ---- 权限模式 ----
general = data.setdefault("general", {})
if bypass_mode == "yes":
    general["defaultPermissionMode"] = "bypass_permissions"
    print("      已设置 general.defaultPermissionMode = bypass_permissions(免确认;WARN 由守卫硬拒)")
else:
    print("      已跳过权限模式设置(--no-bypass);WARN 会弹确认框。")

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

echo "[3/3] 完成 ✅"
echo
echo "请重启 Qoder(新会话生效)。"
echo "验证钩子:"
echo "  echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | /usr/bin/python3 ${SCRIPT_DST}"
echo
echo "说明:与 Claude 同源 —— deny 压得住免确认模式;但 WARN 档在免确认下弹不了框,"
echo "      所以一律硬拒,想放行某类命令就写进 ~/.claude/hooks/allowlist.txt(各家共享)。"
