#!/usr/bin/env bash
# opencode 集成回归测试:在临时 OPENCODE_HOME 里跑 install-opencode.sh,验证
#   1) 落点正确(plugin/bypass-yes-opencode.js + hooks/ 三件套)
#   2) 插件端到端(直接 import 跑 tool.execute.before):block/warn → throw,日常放行
#   3) 只管 bash 工具,read/edit 之类不碰
#   4) 桥接脚本挂掉时 fail-open(不阻断 opencode)
#   5) 幂等:重复安装不报错、文件仍在
# 需要 node(跑插件)。用法:bash test-opencode.sh   (退出码非 0 表示有用例不通过)
set -u
export DANGER_GUARD_SILENT=1 DANGER_GUARD_ASK=0

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-/usr/bin/python3}"
NODE="${NODE:-node}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/opencode-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
TESTCWD="$HOME/testproj/app"

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (期望 [$1] 实得 [$2])"; fi; }

if ! command -v "$NODE" >/dev/null 2>&1; then
  echo "跳过:没找到 node(插件跑不起来)。设 NODE=<路径> 或装 node 后重跑。"
  exit 0
fi

echo "== 安装 opencode 守卫到临时目录 =="
OPENCODE_HOME="$TMP" bash "$SRC_DIR/install-opencode.sh" >/dev/null 2>&1
PLUGIN="$TMP/plugin/bypass-yes-opencode.js"

echo "== 落点 =="
[ -f "$PLUGIN" ] && ok "plugin/bypass-yes-opencode.js" || bad "插件没装上"
for f in danger-guard-pi.py core.py rules.py; do
  [ -f "$TMP/hooks/$f" ] && ok "hooks/$f" || bad "hooks/$f 缺失"
done

# 用 node 跑插件:输出 blocked:<原因> 或 allowed
run_hook() { # run_hook <tool> <command> [guard路径覆盖]
  TOOL="$1" CMD="$2" CWD="$TESTCWD" PLUGIN="$PLUGIN" "$NODE" --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const factory = Object.values(mod).find((v) => typeof v === "function");
const hooks = await factory({ directory: process.env.CWD, worktree: process.env.CWD });
try {
  await hooks["tool.execute.before"]({ tool: process.env.TOOL }, { args: { command: process.env.CMD } });
  console.log("allowed");
} catch (e) {
  console.log("blocked:" + e.message);
}' 2>/dev/null
}
verdict() { case "$(run_hook "$1" "$2")" in blocked:*) echo blocked ;; allowed) echo allowed ;; *) echo err ;; esac; }

echo "== 端到端:block/warn 拦下,日常放行 =="
assert_eq "blocked" "$(verdict bash 'rm -rf /')" "rm -rf / → 拦下"
assert_eq "blocked" "$(verdict bash 'mkfs.ext4 /dev/sda1')" "mkfs → 拦下"
assert_eq "blocked" "$(verdict bash 'git reset --hard HEAD~1')" "git reset --hard(WARN)→ 拦下"
assert_eq "blocked" "$(verdict bash "rm -rf $HOME/testproj")" "rm -rf 整个项目(WARN)→ 拦下"
assert_eq "blocked" "$(verdict bash 'npm publish')" "npm publish(WARN)→ 拦下"
assert_eq "allowed" "$(verdict bash 'rm -rf node_modules')" "rm -rf node_modules → 放行"
assert_eq "allowed" "$(verdict bash 'rm -rf /tmp/foo')" "rm -rf /tmp/foo → 放行"
assert_eq "allowed" "$(verdict bash 'ls -la')" "ls -la → 放行"
assert_eq "allowed" "$(verdict bash 'echo "rm -rf /"')" "echo 里的危险串(只是数据)→ 放行"
assert_eq "allowed" "$(verdict bash '   ')" "空命令 → 放行"

echo "== 拦截原因带上了规则说明 =="
case "$(run_hook bash 'git reset --hard HEAD~1')" in
  *"[命令守卫]"*"丢弃改动"*) ok "错误文案含 [命令守卫] 与原因" ;;
  *) bad "错误文案不对: $(run_hook bash 'git reset --hard HEAD~1')" ;;
esac

echo "== 只管 bash 工具 =="
assert_eq "allowed" "$(verdict read 'rm -rf /')" "read 工具 → 不碰"
assert_eq "allowed" "$(verdict edit 'rm -rf /')" "edit 工具 → 不碰"

echo "== 桥接挂掉时 fail-open =="
mv "$TMP/hooks/danger-guard-pi.py" "$TMP/hooks/danger-guard-pi.py.off"
assert_eq "allowed" "$(verdict bash 'rm -rf /')" "桥接缺失 → 放行(不阻断 opencode)"
mv "$TMP/hooks/danger-guard-pi.py.off" "$TMP/hooks/danger-guard-pi.py"

echo "== 幂等:重复安装 =="
OPENCODE_HOME="$TMP" bash "$SRC_DIR/install-opencode.sh" >/dev/null 2>&1
assert_eq "blocked" "$(verdict bash 'rm -rf /')" "重复安装后仍拦得住"

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
