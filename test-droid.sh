#!/usr/bin/env bash
# Factory droid 集成回归测试:在临时 FACTORY_HOME 里跑 install-droid.sh,验证
#   1) 生成的 hooks.json 结构正确(根级 PreToolUse / matcher=Execute)
#   2) 端到端:block → deny,warn → ask,日常放行(工具名 Execute)
#   3) permission_mode = auto-* 时 WARN 升 deny(auto 档弹不出确认框)
#   4) 幂等:重复安装只剩一条,别人的钩子不被吃掉
# 注意:这里验的是「守卫判得对不对 + 配置写得对不对」,验不了「droid 有没有真调用它」——
#       本机没装 droid,那一步请用 danger-guard-canary.sh 在真环境里取证。
# 用法:bash test-droid.sh   (退出码非 0 表示有用例不通过)
set -u
export DANGER_GUARD_SILENT=1 DANGER_GUARD_ASK=0

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-/usr/bin/python3}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/droid-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
TESTCWD="$HOME/testproj/app"

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (期望 [$1] 实得 [$2])"; fi; }
json_str() { "$PY" -c 'import sys,json;print(json.dumps(sys.argv[1]))' "$1"; }
jq_get()   { "$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{"d":d}))' "$1" "$2"; }

echo "== 安装 droid 守卫到临时目录(并预置一条别人的钩子)=="
mkdir -p "$TMP"
printf '%s' '{"PreToolUse":[{"matcher":"Create","hooks":[{"type":"command","command":"true"}]}]}' > "$TMP/hooks.json"
FACTORY_HOME="$TMP" bash "$SRC_DIR/install-droid.sh" >/dev/null 2>&1
HOOKS_JSON="$TMP/hooks.json"
GUARD="$TMP/hooks/danger-guard.py"

echo "== hooks.json 结构 =="
assert_eq "Execute" "$(jq_get "$HOOKS_JSON" 'd["PreToolUse"][0]["matcher"]')" "matcher = Execute"
assert_eq "2" "$(jq_get "$HOOKS_JSON" 'len(d["PreToolUse"])')" "别人的钩子还在(共 2 条)"
case "$(jq_get "$HOOKS_JSON" 'd["PreToolUse"][0]["hooks"][0]["command"]')" in
  *"danger-guard.py"*) ok "command 指向 danger-guard.py" ;;
  *) bad "command 未指向 danger-guard.py" ;;
esac

# decision_of <command> [permission_mode] -> deny/ask/none
decision_of() {
  local mode="${2:-}" extra="" out
  [ -n "$mode" ] && extra=",\"permission_mode\":$(json_str "$mode")"
  out=$(printf '%s' "{\"tool_name\":\"Execute\",\"tool_input\":{\"command\":$(json_str "$1")},\"cwd\":$(json_str "$TESTCWD")$extra}" | "$PY" "$GUARD" 2>/dev/null)
  if [ -z "$out" ]; then echo none; return; fi
  printf '%s' "$out" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null || echo parse_err
}

echo "== 端到端:block → deny,warn → ask,日常放行 =="
assert_eq "deny" "$(decision_of 'rm -rf /')" "rm -rf / → deny"
assert_eq "deny" "$(decision_of 'mkfs.ext4 /dev/sda1')" "mkfs → deny"
assert_eq "ask"  "$(decision_of 'git reset --hard HEAD~1')" "git reset --hard(WARN)→ ask"
assert_eq "ask"  "$(decision_of "rm -rf $HOME/testproj")" "rm -rf 整个项目(WARN)→ ask"
assert_eq "none" "$(decision_of 'rm -rf node_modules')" "rm -rf node_modules → none"
assert_eq "none" "$(decision_of 'ls -la')" "ls -la → none"

echo "== permission_mode =="
assert_eq "ask"  "$(decision_of 'git reset --hard HEAD~1' off)"          "off → 仍是 ask"
assert_eq "ask"  "$(decision_of 'git reset --hard HEAD~1' spec)"         "spec → 仍是 ask"
assert_eq "deny" "$(decision_of 'git reset --hard HEAD~1' auto-low)"     "auto-low → 升 deny"
assert_eq "deny" "$(decision_of 'git reset --hard HEAD~1' auto-medium)"  "auto-medium → 升 deny"
assert_eq "deny" "$(decision_of 'git reset --hard HEAD~1' auto-high)"    "auto-high → 升 deny"

echo "== 空命令 / 坏输入:不拦 =="
out=$(printf '%s' '{"tool_name":"Execute","tool_input":{"command":"   "}}' | "$PY" "$GUARD" 2>/dev/null)
assert_eq "" "$out" "空命令 → 无输出"
out=$(printf '%s' 'not-json' | "$PY" "$GUARD" 2>/dev/null)
assert_eq "" "$out" "非法 JSON → 无输出"

echo "== 幂等:重复安装仍 2 条 =="
FACTORY_HOME="$TMP" bash "$SRC_DIR/install-droid.sh" >/dev/null 2>&1
assert_eq "2" "$(jq_get "$HOOKS_JSON" 'len(d["PreToolUse"])')" "重复安装后仍 2 条"

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
