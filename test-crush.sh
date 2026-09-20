#!/usr/bin/env bash
# Crush 集成回归测试:在临时 CRUSH_HOME 里跑 install-crush.sh,验证
#   1) 生成的 crush.json 结构正确(hooks.PreToolUse / name / matcher)
#   2) 装好的 danger-guard-crush.py 端到端:block/warn → deny,日常放行
#   3) 只管 tool_name == "bash"
#   4) 幂等:重复安装只剩一条 bypass-yes,且别人的钩子和别的配置不被吃掉
# 注意:这里验的是「守卫判得对不对 + 配置写得对不对」,验不了「Crush 有没有真调用它」——
#       本机没装 Crush,那一步请用 danger-guard-canary.sh 在真环境里取证。
# 用法:bash test-crush.sh   (退出码非 0 表示有用例不通过)
set -u
export DANGER_GUARD_SILENT=1 DANGER_GUARD_ASK=0

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-/usr/bin/python3}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/crush-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
TESTCWD="$HOME/testproj/app"

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (期望 [$1] 实得 [$2])"; fi; }
json_str() { "$PY" -c 'import sys,json;print(json.dumps(sys.argv[1]))' "$1"; }
jq_get()   { "$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{"d":d}))' "$1" "$2"; }

echo "== 安装 Crush 守卫到临时目录(并预置一份已有配置)=="
mkdir -p "$TMP"
printf '%s' '{"options":{"request_timeout":300},"hooks":{"PreToolUse":[{"name":"someone-else","command":"true"}]}}' > "$TMP/crush.json"
CRUSH_HOME="$TMP" bash "$SRC_DIR/install-crush.sh" >/dev/null 2>&1
CONFIG="$TMP/crush.json"
GUARD="$TMP/hooks/danger-guard-crush.py"

echo "== crush.json 结构 =="
assert_eq "bypass-yes" "$(jq_get "$CONFIG" 'd["hooks"]["PreToolUse"][0]["name"]')" "第一条是 bypass-yes"
assert_eq "^bash$" "$(jq_get "$CONFIG" 'd["hooks"]["PreToolUse"][0]["matcher"]')" "matcher = ^bash$"
case "$(jq_get "$CONFIG" 'd["hooks"]["PreToolUse"][0]["command"]')" in
  *"danger-guard-crush.py"*) ok "command 指向 danger-guard-crush.py" ;;
  *) bad "command 未指向 danger-guard-crush.py" ;;
esac
assert_eq "2" "$(jq_get "$CONFIG" 'len(d["hooks"]["PreToolUse"])')" "别人的钩子还在(共 2 条)"
assert_eq "300" "$(jq_get "$CONFIG" 'd["options"]["request_timeout"]')" "别的配置没被吃掉"

# decision_of <command> [tool] -> deny/none
decision_of() {
  local tool="${2:-bash}" out
  out=$(printf '%s' "{\"event\":\"PreToolUse\",\"tool_name\":\"$tool\",\"tool_input\":{\"command\":$(json_str "$1")},\"cwd\":$(json_str "$TESTCWD")}" | "$PY" "$GUARD" 2>/dev/null)
  if [ -z "$out" ]; then echo none; return; fi
  printf '%s' "$out" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["decision"])' 2>/dev/null || echo parse_err
}

echo "== 端到端:block/warn → deny,日常放行 =="
assert_eq "deny" "$(decision_of 'rm -rf /')" "rm -rf / → deny"
assert_eq "deny" "$(decision_of 'mkfs.ext4 /dev/sda1')" "mkfs → deny"
assert_eq "deny" "$(decision_of 'git reset --hard HEAD~1')" "git reset --hard(WARN)→ deny"
assert_eq "deny" "$(decision_of "rm -rf $HOME/testproj")" "rm -rf 整个项目(WARN)→ deny"
assert_eq "deny" "$(decision_of 'npm publish')" "npm publish(WARN)→ deny"
assert_eq "none" "$(decision_of 'rm -rf node_modules')" "rm -rf node_modules → none"
assert_eq "none" "$(decision_of 'rm -rf /tmp/foo')" "rm -rf /tmp/foo → none"
assert_eq "none" "$(decision_of 'ls -la')" "ls -la → none"
assert_eq "none" "$(decision_of 'echo "rm -rf /"')" "echo 里的危险串(只是数据)→ none"

echo "== 只管 bash 工具 =="
assert_eq "none" "$(decision_of 'rm -rf /' view)" "view 工具 → none"
assert_eq "none" "$(decision_of 'rm -rf /' Bash)" "大写 Bash(不是 Crush 的工具名)→ none"

echo "== 空命令 / 坏输入:不拦 =="
out=$(printf '%s' '{"tool_name":"bash","tool_input":{"command":"   "}}' | "$PY" "$GUARD" 2>/dev/null)
assert_eq "" "$out" "空命令 → 无输出"
out=$(printf '%s' 'not-json' | "$PY" "$GUARD" 2>/dev/null)
assert_eq "" "$out" "非法 JSON → 无输出"

echo "== 幂等:重复安装仍 2 条 =="
CRUSH_HOME="$TMP" bash "$SRC_DIR/install-crush.sh" >/dev/null 2>&1
assert_eq "2" "$(jq_get "$CONFIG" 'len(d["hooks"]["PreToolUse"])')" "重复安装后仍 2 条"

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
