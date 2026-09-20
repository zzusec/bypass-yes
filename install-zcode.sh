#!/usr/bin/env bash
# zcode 命令守卫 — 安装脚本 (macOS)
#
# zcode(Z.AI 的 CLI)是 Claude Code 的同构克隆:hook 事件名同为 PreToolUse,输入 JSON
# 同构(hook_event_name / tool_name / tool_input.command / cwd),输出同样读
# hookSpecificOutput.permissionDecision 的 deny/ask,工具名同为 Bash。所以直接复用
# danger-guard.py,判定引擎 core.py 与规则库 rules.py 也是同一份。
#
# 两点与 Claude 不同:
#   1) 配置文件是 ~/.zcode/cli/setting.json(单数 setting),不是 settings.json;
#      hook 挂在 hooks.events.PreToolUse,且要 hooks.enabled=true 才生效。
#      (~/.zcode/cli/config.json 是旧文件,启动时合并一次,不作为运行时 fallback。)
#   2) 免确认模式叫 permission.mode="yolo"(不是 bypassPermissions)。
#      zcode 运行时实测:hook 的 deny 永远生效、yolo 也压不住;本项目按既定策略把
#      zcode 当 bypass 处理(core.is_bypass_mode 读 setting.json),WARN 一律硬拒。
#
# 用法:
#   bash install-zcode.sh              # 装钩子并把 permission.mode 设为 yolo(默认)
#   bash install-zcode.sh --no-bypass  # 只装钩子,不动权限模式(build/edit 下 WARN 会弹确认)
set -euo pipefail

ZCODE_DIR="${ZCODE_HOME:-${HOME}/.zcode}"
CLI_DIR="${ZCODE_DIR}/cli"
HOOKS_DIR="${CLI_DIR}/hooks"
SETTINGS="${CLI_DIR}/setting.json"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DST="${HOOKS_DIR}/danger-guard.py"

BYPASS_MODE="yes"
for arg in "$@"; do
  case "$arg" in
    --bypass|-y) BYPASS_MODE="yes" ;;
    --no-bypass) BYPASS_MODE="no" ;;
    *) echo "用法: bash install-zcode.sh [--bypass|--no-bypass]" >&2; exit 1 ;;
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

echo "[2/3] 合并 PreToolUse hook + 设 yolo 权限模式 -> ${SETTINGS}"
if [ ! -f "${SETTINGS}" ]; then
  echo "      提示: ${SETTINGS} 不存在(没跑过 zcode?),将新建一个最小配置;zcode 会自动补默认值。"
fi
/usr/bin/python3 - "$SETTINGS" "$SCRIPT_DST" "$SRC_DIR" "$BYPASS_MODE" <<'PY'
import json, os, sys

settings_path, script_dst, src_dir, bypass_mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, src_dir)
import rules

if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as f:
        data = json.load(f)
    bak = settings_path + ".bak.cmdguard"
    with open(bak, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("      已备份原配置 ->", bak)
else:
    data = {}

# ---- hooks.events.PreToolUse ----
hooks = data.setdefault("hooks", {})
hooks["enabled"] = True                      # 不开这个,所有 hook 静默不执行
events = hooks.setdefault("events", {})
pre = events.setdefault("PreToolUse", [])

entry = {
    "matcher": "Bash",
    "hooks": [
        {"type": "command", "command": "/usr/bin/python3 %s" % script_dst, "timeoutMs": 60000}
    ],
}


def points_to_guard(e):
    return any("danger-guard.py" in h.get("command", "") for h in (e.get("hooks") or []))


# 去重后放最前,保证先于其它 hook 判定
pre[:] = [e for e in pre if not points_to_guard(e)]
pre.insert(0, entry)
print("      已写入 PreToolUse hook(hooks.enabled=true)")

# ---- permission ----
perm = data.setdefault("permission", {})
if bypass_mode == "yes":
    perm["mode"] = "yolo"
    print("      已设置 permission.mode = yolo(免确认;WARN 由守卫硬拒)")

    # 静态 deny 兜底(hook 被关时也拦毁灭级删除/磁盘)。条目来自规则库,不另维护第二份。
    # ⚠ 与 Claude 同理:deny 的 * 会跨 / 匹配,所以只放精确的毁灭级形态(CLAUDE_DENY),
    #   并剔除已知过宽条目(CLAUDE_DENY_OVERBROAD),路径分级交给 danger-guard.py。
    old = list(perm.get("disallowedTools") or [])
    kept = [x for x in old if x not in rules.CLAUDE_DENY_OVERBROAD]
    removed = [x for x in old if x in rules.CLAUDE_DENY_OVERBROAD]
    for x in rules.CLAUDE_DENY:
        if x not in kept:
            kept.append(x)
    perm["disallowedTools"] = kept
    print("      静态 disallowedTools:", kept)
    if removed:
        print("      已移除过宽条目:", removed)
else:
    print("      已跳过权限模式设置(--no-bypass);build/edit 下 WARN 会弹确认框。")

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

echo "[3/3] 完成 ✅"
echo
echo "请重启 zcode(新会话生效)。"
echo "验证钩子:"
echo "  echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | /usr/bin/python3 ${SCRIPT_DST}"
echo
echo "注意:zcode 的 yolo 下 hook 的 deny 永远生效(运行时实测),守卫拦得住;"
echo "      本项目把 zcode 当 bypass 处理,git reset --hard / rm -rf 整个项目 等 WARN 一律硬拒,"
echo "      想放行某类命令就写进 ~/.claude/hooks/allowlist.txt(九家共享)。"
