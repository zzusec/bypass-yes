#!/usr/bin/env bash
# Cursor 集成回归测试:在临时 CURSOR_HOME 里跑 install-cursor.sh,验证
#   1) 生成的 hooks.json 结构正确(version = 1 / beforeShellExecution 条目)
#   2) 装好的 danger-guard-cursor.py 端到端:block → deny,warn → ask,日常放行
#   3) cwd 缺失时回退到 workspace_roots[0]
#   4) DANGER_GUARD_BYPASS=1 时 WARN 升 deny(免确认模式下的兜底)
#   5) 幂等:重复安装 beforeShellExecution 只剩一条
# 用法:bash test-cursor.sh   (退出码非 0 表示有用例不通过)
set -u
export DANGER_GUARD_SILENT=1 DANGER_GUARD_ASK=0

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-/usr/bin/python3}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cursor-test.XXXXXX")"
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

echo "== 安装 Cursor 守卫到临时目录 =="
CURSOR_HOME="$TMP" bash "$SRC_DIR/install-cursor.sh" >/dev/null 2>&1
HOOKS_JSON="$TMP/hooks.json"
GUARD="$TMP/hooks/danger-guard-cursor.py"

echo "== hooks.json 结构 =="
assert_eq "1" "$(jq_get "$HOOKS_JSON" 'd["version"]')" "version = 1"
assert_eq "1" "$(jq_get "$HOOKS_JSON" 'len(d["hooks"]["beforeShellExecution"])')" "beforeShellExecution 恰好 1 条"
case "$(jq_get "$HOOKS_JSON" 'd["hooks"]["beforeShellExecution"][0]["command"]')" in
  *"danger-guard-cursor.py"*) ok "hook command 指向 danger-guard-cursor.py" ;;
  *) bad "hook command 未指向 danger-guard-cursor.py" ;;
esac

# decision_of <command> -> deny/ask/none
decision_of() {
  local out
  out=$(printf '%s' "{\"hook_event_name\":\"beforeShellExecution\",\"command\":$(json_str "$1"),\"cwd\":$(json_str "$TESTCWD")}" | "$PY" "$GUARD" 2>/dev/null)
  if [ -z "$out" ]; then echo none; return; fi
  printf '%s' "$out" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["permission"])' 2>/dev/null || echo parse_err
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

echo "== cwd 缺失时回退 workspace_roots[0] =="
out=$(printf '%s' "{\"command\":$(json_str "rm -rf $HOME/testproj"),\"workspace_roots\":[$(json_str "$HOME/testproj")]}" | "$PY" "$GUARD" 2>/dev/null)
dec=$(printf '%s' "$out" | "$PY" -c 'import sys,json;d=sys.stdin.read();print(json.loads(d)["permission"] if d.strip() else "none")' 2>/dev/null)
assert_eq "ask" "$dec" "无 cwd 时用 workspace_roots[0] 判整个项目 → ask"

echo "== DANGER_GUARD_BYPASS=1:WARN 升 deny =="
out=$(printf '%s' "{\"command\":\"git reset --hard HEAD~1\",\"cwd\":$(json_str "$TESTCWD")}" | DANGER_GUARD_BYPASS=1 "$PY" "$GUARD" 2>/dev/null)
dec=$(printf '%s' "$out" | "$PY" -c 'import sys,json;d=sys.stdin.read();print(json.loads(d)["permission"] if d.strip() else "none")' 2>/dev/null)
assert_eq "deny" "$dec" "bypass=1 时 git reset --hard → deny"

echo "== 空命令 / 坏输入:不拦 =="
out=$(printf '%s' '{"command":"   "}' | "$PY" "$GUARD" 2>/dev/null)
assert_eq "" "$out" "空命令 → 无输出"
out=$(printf '%s' 'not-json' | "$PY" "$GUARD" 2>/dev/null)
assert_eq "" "$out" "非法 JSON → 无输出"

echo "== 幂等:重复安装 beforeShellExecution 仍 1 条 =="
CURSOR_HOME="$TMP" bash "$SRC_DIR/install-cursor.sh" >/dev/null 2>&1
assert_eq "1" "$(jq_get "$HOOKS_JSON" 'len(d["hooks"]["beforeShellExecution"])')" "重复安装后仍 1 条"

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
