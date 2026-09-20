#!/usr/bin/env bash
# CodeBuddy 集成回归测试:在临时 CODEBUDDY_HOME 里跑 install-codebuddy.sh,验证
#   1) settings.json 结构正确(hooks.PreToolUse / matcher=Bash / defaultMode)
#   2) --no-bypass 时不碰权限模式,且 WARN 仍能弹 ask
#   3) bypass 模式下 WARN 升 deny(客户端会吞 ask)
#   4) 推荐 deny 写进去了,过宽的 deny 被摘掉
#   5) 幂等:重复安装 PreToolUse 只剩一条,别人的钩子不被吃掉
# 判定引擎本身由 test.sh 覆盖(共用 danger-guard.py),这里只验安装脚本和权限模式联动。
# 用法:bash test-codebuddy.sh   (退出码非 0 表示有用例不通过)
set -u
export DANGER_GUARD_SILENT=1 DANGER_GUARD_ASK=0

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-/usr/bin/python3}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codebuddy-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
TESTCWD="$HOME/testproj/app"

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (期望 [$1] 实得 [$2])"; fi; }
json_str() { "$PY" -c 'import sys,json;print(json.dumps(sys.argv[1]))' "$1"; }
jq_get()   { "$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{"d":d}))' "$1" "$2"; }

SETTINGS="$TMP/settings.json"
GUARD="$TMP/hooks/danger-guard.py"

echo "== 安装(默认 bypass)到临时目录,并预置一条别人的钩子 =="
mkdir -p "$TMP"
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"true"}]}]},"permissions":{"deny":["Bash(rm -rf *)","Bash(my-own-rule)"]}}' > "$SETTINGS"
CODEBUDDY_HOME="$TMP" bash "$SRC_DIR/install-codebuddy.sh" >/dev/null 2>&1

echo "== settings.json 结构 =="
assert_eq "Bash" "$(jq_get "$SETTINGS" 'd["hooks"]["PreToolUse"][0]["matcher"]')" "第一条 matcher = Bash"
assert_eq "2" "$(jq_get "$SETTINGS" 'len(d["hooks"]["PreToolUse"])')" "别人的钩子还在(共 2 条)"
assert_eq "bypassPermissions" "$(jq_get "$SETTINGS" 'd["permissions"]["defaultMode"]')" "defaultMode = bypassPermissions"
case "$(jq_get "$SETTINGS" 'd["hooks"]["PreToolUse"][0]["hooks"][0]["command"]')" in
  *"danger-guard.py"*) ok "command 指向 danger-guard.py" ;;
  *) bad "command 未指向 danger-guard.py" ;;
esac
[ -f "$GUARD" ] && ok "danger-guard.py 已复制" || bad "danger-guard.py 没装上"
[ -f "$TMP/hooks/core.py" ] && [ -f "$TMP/hooks/rules.py" ] && ok "core.py + rules.py 已复制" || bad "规则库没跟着复制"

echo "== 推荐 deny 写入 / 过宽 deny 摘除 =="
assert_eq "False" "$(jq_get "$SETTINGS" '"Bash(rm -rf *)" in d["permissions"]["deny"]')" "过宽的 Bash(rm -rf *) 已移除"
assert_eq "True" "$(jq_get "$SETTINGS" '"Bash(my-own-rule)" in d["permissions"]["deny"]')" "用户自己的 deny 保留"
assert_eq "True" "$(jq_get "$SETTINGS" 'len(d["permissions"]["deny"]) > 0')" "推荐 deny 非空"

# decision_of <command> -> deny/ask/none(用装好的那份,client_dir 指向临时目录)
decision_of() {
  local out
  out=$(printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "$1")},\"cwd\":$(json_str "$TESTCWD")}" | "$PY" "$GUARD" 2>/dev/null)
  if [ -z "$out" ]; then echo none; return; fi
  printf '%s' "$out" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null || echo parse_err
}

echo "== bypass 模式:WARN 升 deny(客户端会吞 ask)=="
assert_eq "deny" "$(decision_of 'rm -rf /')" "rm -rf / → deny"
assert_eq "deny" "$(decision_of 'git reset --hard HEAD~1')" "git reset --hard(WARN)→ deny"
assert_eq "none" "$(decision_of 'ls -la')" "ls -la → none"

echo "== 幂等:重复安装仍 2 条 =="
CODEBUDDY_HOME="$TMP" bash "$SRC_DIR/install-codebuddy.sh" >/dev/null 2>&1
assert_eq "2" "$(jq_get "$SETTINGS" 'len(d["hooks"]["PreToolUse"])')" "重复安装后仍 2 条"

echo "== --no-bypass:不碰权限模式,WARN 回到 ask =="
TMP2="$(mktemp -d "${TMPDIR:-/tmp}/codebuddy-test2.XXXXXX")"
CODEBUDDY_HOME="$TMP2" bash "$SRC_DIR/install-codebuddy.sh" --no-bypass >/dev/null 2>&1
assert_eq "False" "$(jq_get "$TMP2/settings.json" '"defaultMode" in d.get("permissions",{})')" "没写 defaultMode"
out=$(printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard HEAD~1\"},\"cwd\":$(json_str "$TESTCWD")}" | "$PY" "$TMP2/hooks/danger-guard.py" 2>/dev/null)
dec=$(printf '%s' "$out" | "$PY" -c 'import sys,json;d=sys.stdin.read();print(json.loads(d)["hookSpecificOutput"]["permissionDecision"] if d.strip() else "none")' 2>/dev/null)
assert_eq "ask" "$dec" "--no-bypass 时 git reset --hard → ask"
rm -rf "$TMP2"

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
