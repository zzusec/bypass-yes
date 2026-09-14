#!/usr/bin/env bash
# Codex CLI 命令守卫 — 安装脚本 (macOS)
# 复制脚本/铃声到 ~/.codex/hooks/,合并 hooks.json,安装 danger-guard.rules,
# 检测其他 .rules 文件里会压过 prompt 的 forbidden 冲突条目,
# 并把「上下文到 80% 自动 compact」配上。
#
# 用法:
#   bash install-codex.sh                    # 默认阈值 80%
#   bash install-codex.sh --autocompact-pct 75
#   bash install-codex.sh --no-autocompact   # 不动自动压缩配置
#   bash install-codex.sh --codex-window 272000   # config.toml 没写窗口时手动给
set -euo pipefail

AUTOCOMPACT=1
AUTOCOMPACT_PCT=80
CODEX_WINDOW=""
prev=""
for arg in "$@"; do
  case "$arg" in
    --no-autocompact) AUTOCOMPACT=0 ;;
    --autocompact-pct=*) AUTOCOMPACT_PCT="${arg#*=}" ;;
    --codex-window=*) CODEX_WINDOW="${arg#*=}" ;;
    *)
      [ "$prev" = "--autocompact-pct" ] && AUTOCOMPACT_PCT="$arg"
      [ "$prev" = "--codex-window" ] && CODEX_WINDOW="$arg"
      ;;
  esac
  prev="$arg"
done

CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
HOOKS_DIR="${CODEX_DIR}/hooks"
RULES_DIR="${CODEX_DIR}/rules"
HOOKS_JSON="${CODEX_DIR}/hooks.json"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DST="${HOOKS_DIR}/danger-guard-codex.py"

echo "[1/5] 复制脚本与铃声 -> ${HOOKS_DIR}"
mkdir -p "${HOOKS_DIR}" "${RULES_DIR}"
cp "${SRC_DIR}/danger-guard-codex.py" "${SCRIPT_DST}"
cp "${SRC_DIR}/core.py" "${SRC_DIR}/rules.py" "${HOOKS_DIR}/"
cp "${SRC_DIR}/chime.wav" "${HOOKS_DIR}/chime.wav"

echo "[2/5] 合并 PreToolUse + PermissionRequest hook -> ${HOOKS_JSON}"
/usr/bin/python3 - "$HOOKS_JSON" "$SCRIPT_DST" <<'PY'
import json, os, sys

hooks_path, script_dst = sys.argv[1], sys.argv[2]

if os.path.exists(hooks_path):
    with open(hooks_path, encoding="utf-8") as f:
        data = json.load(f)
    bak = hooks_path + ".bak.cmdguard"
    with open(bak, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("      已备份原配置 ->", bak)
else:
    data = {}

hooks = data.setdefault("hooks", {})

def points_to_guard(e):
    return any("danger-guard-codex.py" in h.get("command", "") for h in e.get("hooks", []))


def guard_index(lst):
    """danger-guard 条目当前所在的索引(取第一个)。"""
    for i, e in enumerate(lst):
        if points_to_guard(e):
            return i
    return None


# Codex 的 trust hash 跟 hooks.json 的内容绑定:只要命令字符串没变,就一个字节都不改
# (含条目索引和键顺序),否则重装一次就得重新 /hooks Trust,而没 Trust 时钩子是静默
# 不执行的 —— 看不出任何异常。所以这里是「就地更新」而不是「删掉再 append」。
changed = False
for event in ("PreToolUse", "PermissionRequest"):
    lst = hooks.setdefault(event, [])
    cmd = "/usr/bin/python3 %s %s" % (script_dst, event)
    idx = guard_index(lst)

    if idx is None:
        lst.append({"matcher": "Bash",
                    "hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
        changed = True
        continue

    old = lst[idx]
    h = dict((old.get("hooks") or [{}])[0])
    for k, v in (("command", cmd), ("type", "command"), ("timeout", 10)):
        if h.get(k) != v:
            h[k] = v          # 已存在的键赋值不改顺序,缺失的才追加
            changed = True
    new = dict(old)
    new["hooks"] = [h]
    if new != old:
        changed = True
    lst[idx] = new

    # 清掉历史残留的重复条目(保留上面那个索引)
    rest = [e for i, e in enumerate(lst) if i == idx or not points_to_guard(e)]
    if len(rest) != len(lst):
        lst[:] = rest
        changed = True

if changed:
    with open(hooks_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("      已写入 PreToolUse + PermissionRequest hook")
else:
    print("      hooks.json 已是最新,未改动(Codex trust hash 不受影响)")
PY

echo "[3/5] 生成危险确认规则 -> ${RULES_DIR}/danger-guard.rules"
/usr/bin/python3 "${SRC_DIR}/gen_codex_rules.py" "${RULES_DIR}/danger-guard.rules"

echo "[4/5] 检查其他 .rules 文件的 forbidden 冲突(会压过 prompt 弹确认)"
conflict=0
for f in "${RULES_DIR}"/*.rules; do
  [ "$(basename "$f")" = "danger-guard.rules" ] && continue
  if grep -nE 'decision="forbidden"' "$f" | grep -E '"rm"|"git"' >/dev/null 2>&1; then
    conflict=1
    echo "      ⚠ ${f} 中以下 forbidden 条目会压过弹确认(rules 取最严格),建议改为 prompt 或删除:"
    grep -nE 'decision="forbidden"' "$f" | grep -E '"rm"|"git"' | sed 's/^/        /'
  fi
done
if [ "$conflict" -eq 0 ]; then echo "      无冲突"; fi

echo "[5/5] 上下文自动压缩阈值"
if [ "$AUTOCOMPACT" -eq 1 ]; then
  win_args=()
  [ -n "$CODEX_WINDOW" ] && win_args=(--codex-window "$CODEX_WINDOW")
  AUTOCOMPACT_EMBED=1 bash "${SRC_DIR}/autocompact.sh" \
    --codex-only --pct "$AUTOCOMPACT_PCT" "${win_args[@]+"${win_args[@]}"}" | sed 's/^/      /'
else
  echo "      已跳过(--no-autocompact)。"
fi

echo
echo "完成 ✅ 请重启 Codex(新会话生效)。"
echo "验证 hook:"
echo "  echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | /usr/bin/python3 ${SCRIPT_DST} PreToolUse"
echo "验证 rules:"
echo "  codex execpolicy check --rules ${RULES_DIR}/danger-guard.rules --pretty -- git reset --hard HEAD~1"
