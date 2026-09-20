#!/usr/bin/env bash
# Qoder 集成回归测试:在临时 QODER_HOME 里跑 install-qoder.sh,验证
#   1) 生成的 settings.json 结构正确(hooks.PreToolUse 条目 / general.defaultPermissionMode)
#   2) core.is_bypass_mode() 能从中检测出 bypass
#   3) 装好的 danger-guard.py 端到端:免确认下 WARN 升 deny,毁灭级 deny,日常放行
#   4) --no-bypass 时不设权限模式,WARN 回到 ask
#   5) 幂等:重复安装 PreToolUse 只剩一条
# 用法:bash test-qoder.sh   (退出码非 0 表示有用例不通过)
set -u
export DANGER_GUARD_SILENT=1 DANGER_GUARD_ASK=0

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-/usr/bin/python3}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qoder-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
TESTCWD="$HOME/testproj/app"

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { # assert_eq <expected> <actual> <name>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (期望 [$1] 实得 [$2])"; fi
}
json_str() { "$PY" -c 'import sys,json;print(json.dumps(sys.argv[1]))' "$1"; }
jq_get()   { "$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{"d":d}))' "$1" "$2"; }

echo "== 安装 Qoder 守卫(bypass)到临时目录 =="
QODER_HOME="$TMP" bash "$SRC_DIR/install-qoder.sh" >/dev/null 2>&1
SETTINGS="$TMP/settings.json"
GUARD="$TMP/hooks/danger-guard.py"

echo "== settings.json 结构 =="
assert_eq "1"    "$(jq_get "$SETTINGS" 'len(d["hooks"]["PreToolUse"])')" "PreToolUse 恰好 1 条"
assert_eq "Bash" "$(jq_get "$SETTINGS" 'd["hooks"]["PreToolUse"][0]["matcher"]')" "matcher = Bash"
assert_eq "command" "$(jq_get "$SETTINGS" 'd["hooks"]["PreToolUse"][0]["hooks"][0]["type"]')" "hook type = command"
assert_eq "bypass_permissions" "$(jq_get "$SETTINGS" 'd["general"]["defaultPermissionMode"]')" "defaultPermissionMode = bypass_permissions"
case "$(jq_get "$SETTINGS" 'd["hooks"]["PreToolUse"][0]["hooks"][0]["command"]')" in
  *"danger-guard.py"*) ok "hook command 指向 danger-guard.py" ;;
  *) bad "hook command 未指向 danger-guard.py" ;;
esac

echo "== is_bypass_mode() 从 settings.json 检测 bypass =="
assert_eq "True" "$(cd "$TMP/hooks" && "$PY" -c 'import core;print(core.is_bypass_mode())')" "bypass_permissions → bypass=True"

# decision_of <command> -> deny/ask/none(走装好的 guard,自动检测 bypass)
decision_of() {
  local out
  out=$(printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "$1")},\"cwd\":$(json_str "$TESTCWD")}" | "$PY" "$GUARD" 2>/dev/null)
  if [ -z "$out" ]; then echo none; return; fi
  printf '%s' "$out" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null || echo parse_err
}

echo "== 免确认端到端:WARN 升 deny,毁灭级 deny,日常放行 =="
assert_eq "deny" "$(decision_of 'rm -rf /')" "rm -rf / → deny"
assert_eq "deny" "$(decision_of 'mkfs.ext4 /dev/sda1')" "mkfs → deny"
assert_eq "deny" "$(decision_of 'git reset --hard HEAD~1')" "git reset --hard(WARN)→ deny"
assert_eq "deny" "$(decision_of "rm -rf $HOME/testproj")" "rm -rf 整个项目(WARN)→ deny"
assert_eq "deny" "$(decision_of 'git push --force origin main')" "git push --force(WARN)→ deny"
assert_eq "none" "$(decision_of 'rm -rf node_modules')" "rm -rf node_modules → none"
assert_eq "none" "$(decision_of 'rm -rf /tmp/foo')" "rm -rf /tmp/foo → none"
assert_eq "none" "$(decision_of 'ls -la')" "ls -la → none"

echo "== 幂等:重复安装 PreToolUse 仍 1 条 =="
QODER_HOME="$TMP" bash "$SRC_DIR/install-qoder.sh" >/dev/null 2>&1
assert_eq "1" "$(jq_get "$SETTINGS" 'len(d["hooks"]["PreToolUse"])')" "重复安装后 PreToolUse 仍 1 条"

echo "== --no-bypass:不设权限模式,WARN 回到 ask =="
TMP2="$(mktemp -d "${TMPDIR:-/tmp}/qoder-test2.XXXXXX")"
QODER_HOME="$TMP2" bash "$SRC_DIR/install-qoder.sh" --no-bypass >/dev/null 2>&1
S2="$TMP2/settings.json"; G2="$TMP2/hooks/danger-guard.py"
assert_eq "None" "$(jq_get "$S2" 'd.get("general",{}).get("defaultPermissionMode")')" "--no-bypass 未设 defaultPermissionMode"
assert_eq "False" "$(cd "$TMP2/hooks" && "$PY" -c 'import core;print(core.is_bypass_mode())')" "非 bypass → bypass=False"
out=$(printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard HEAD~1\"},\"cwd\":$(json_str "$TESTCWD")}" | "$PY" "$G2" 2>/dev/null)
dec=$(printf '%s' "$out" | "$PY" -c 'import sys,json;d=sys.stdin.read();print(json.loads(d)["hookSpecificOutput"]["permissionDecision"] if d.strip() else "none")' 2>/dev/null)
assert_eq "ask" "$dec" "--no-bypass 下 git reset --hard → ask"
rm -rf "$TMP2"

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
