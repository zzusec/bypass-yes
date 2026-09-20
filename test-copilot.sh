#!/usr/bin/env bash
# GitHub Copilot CLI 集成回归测试:在临时 COPILOT_HOME 里跑 install-copilot.sh,验证
#   1) 生成的 hooks/bypass-yes.json 结构正确(version / PreToolUse / matcher=Bash / exec+args)
#   2) 端到端:block → deny,warn → ask,日常放行
#   3) 输出是平铺的 permissionDecision,没有 hookSpecificOutput 包装
#   4) fail-closed 防护:任何坏输入都必须 exit 0(非 0 会让 Copilot 拒掉所有命令)
#   5) 幂等:重复安装结构不变,目录里别人的 *.json 不受影响
# 注意:这里验的是「守卫判得对不对 + 配置写得对不对」,验不了「Copilot 有没有真调用它」——
#       本机没装 copilot,那一步请用 danger-guard-canary.sh 在真环境里取证。
# 用法:bash test-copilot.sh   (退出码非 0 表示有用例不通过)
set -u
export DANGER_GUARD_SILENT=1 DANGER_GUARD_ASK=0

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-/usr/bin/python3}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/copilot-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
TESTCWD="$HOME/testproj/app"

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (期望 [$1] 实得 [$2])"; fi; }
json_str() { "$PY" -c 'import sys,json;print(json.dumps(sys.argv[1]))' "$1"; }
jq_get()   { "$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{"d":d}))' "$1" "$2"; }

echo "== 安装 Copilot 守卫到临时目录(并预置别人的钩子文件)=="
mkdir -p "$TMP/hooks"
printf '%s' '{"version":1,"hooks":{"preToolUse":[{"type":"command","bash":"true"}]}}' > "$TMP/hooks/someone-else.json"
COPILOT_HOME="$TMP" bash "$SRC_DIR/install-copilot.sh" >/dev/null 2>&1
HOOKS_JSON="$TMP/hooks/bypass-yes.json"
GUARD="$TMP/hooks/danger-guard-copilot.py"

echo "== hooks/bypass-yes.json 结构 =="
assert_eq "1" "$(jq_get "$HOOKS_JSON" 'd["version"]')" "version = 1"
assert_eq "Bash" "$(jq_get "$HOOKS_JSON" 'd["hooks"]["PreToolUse"][0]["matcher"]')" "matcher = Bash(Claude 工具名)"
assert_eq "1" "$(jq_get "$HOOKS_JSON" 'len(d["hooks"]["PreToolUse"])')" "PreToolUse 恰好 1 条"
case "$(jq_get "$HOOKS_JSON" 'd["hooks"]["PreToolUse"][0]["args"][0]')" in
  *"danger-guard-copilot.py"*) ok "args 指向 danger-guard-copilot.py" ;;
  *) bad "args 未指向 danger-guard-copilot.py" ;;
esac
[ -f "$TMP/hooks/someone-else.json" ] && ok "别人的钩子文件还在" || bad "别人的钩子文件被删了"

# decision_of <command> -> deny/ask/none
decision_of() {
  local out
  out=$(printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "$1")},\"cwd\":$(json_str "$TESTCWD")}" | "$PY" "$GUARD" 2>/dev/null)
  if [ -z "$out" ]; then echo none; return; fi
  printf '%s' "$out" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["permissionDecision"])' 2>/dev/null || echo parse_err
}

echo "== 端到端:block → deny,warn → ask,日常放行 =="
assert_eq "deny" "$(decision_of 'rm -rf /')" "rm -rf / → deny"
assert_eq "deny" "$(decision_of 'mkfs.ext4 /dev/sda1')" "mkfs → deny"
assert_eq "ask"  "$(decision_of 'git reset --hard HEAD~1')" "git reset --hard(WARN)→ ask"
assert_eq "ask"  "$(decision_of "rm -rf $HOME/testproj")" "rm -rf 整个项目(WARN)→ ask"
assert_eq "ask"  "$(decision_of 'npm publish')" "npm publish(WARN)→ ask"
assert_eq "none" "$(decision_of 'rm -rf node_modules')" "rm -rf node_modules → none"
assert_eq "none" "$(decision_of 'rm -rf /tmp/foo')" "rm -rf /tmp/foo → none"
assert_eq "none" "$(decision_of 'ls -la')" "ls -la → none"
assert_eq "none" "$(decision_of 'echo "rm -rf /"')" "echo 里的危险串(只是数据)→ none"

echo "== 输出是平铺的,没有 hookSpecificOutput 包装 =="
out=$(printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"},\"cwd\":\"/tmp\"}" | "$PY" "$GUARD" 2>/dev/null)
assert_eq "False" "$(printf '%s' "$out" | "$PY" -c 'import sys,json;print("hookSpecificOutput" in json.load(sys.stdin))')" "没有 hookSpecificOutput"
case "$out" in *'"permissionDecisionReason"'*) ok "带 permissionDecisionReason" ;; *) bad "缺 permissionDecisionReason" ;; esac

echo "== DANGER_GUARD_BYPASS=1:WARN 升 deny =="
out=$(printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard HEAD~1\"},\"cwd\":$(json_str "$TESTCWD")}" | DANGER_GUARD_BYPASS=1 "$PY" "$GUARD" 2>/dev/null)
dec=$(printf '%s' "$out" | "$PY" -c 'import sys,json;d=sys.stdin.read();print(json.loads(d)["permissionDecision"] if d.strip() else "none")' 2>/dev/null)
assert_eq "deny" "$dec" "bypass=1 时 git reset --hard → deny"

echo "== fail-closed 防护:任何情况都得 exit 0 =="
# Copilot 对 preToolUse 是 fail-closed —— 非 0 退出会拒掉所有命令,所以这几条必须全是 0
for bad_input in 'not-json' '' '{}' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":null}' '{"tool_name":123}'; do
  printf '%s' "$bad_input" | "$PY" "$GUARD" >/dev/null 2>&1
  assert_eq "0" "$?" "坏输入 [${bad_input:-空}] → exit 0"
done
# core.py 丢了也不能非 0 退出(装坏时不能把 Copilot 锁死)
mv "$TMP/hooks/core.py" "$TMP/hooks/core.py.off"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "$PY" "$GUARD" >/dev/null 2>&1
assert_eq "0" "$?" "core.py 缺失 → 仍 exit 0"
mv "$TMP/hooks/core.py.off" "$TMP/hooks/core.py"

echo "== 幂等:重复安装结构不变 =="
COPILOT_HOME="$TMP" bash "$SRC_DIR/install-copilot.sh" >/dev/null 2>&1
assert_eq "1" "$(jq_get "$HOOKS_JSON" 'len(d["hooks"]["PreToolUse"])')" "重复安装后仍 1 条"
assert_eq "deny" "$(decision_of 'rm -rf /')" "重复安装后仍拦得住"

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
