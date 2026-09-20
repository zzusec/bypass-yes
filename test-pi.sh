#!/usr/bin/env bash
# pi 集成回归测试,两部分:
#   A) 桥接脚本 danger-guard-pi.py 的输出契约(纯 python3,任何机器都能跑)
#   B) 扩展 bypass-yes-guard.ts 的拦截行为(用 pi 自带的 jiti 加载 TS,mock pi/ctx 驱动
#      tool_call,对真实桥接脚本断言 block/allow)—— 没装 pi 就自动跳过这部分
# 用法:bash test-pi.sh   (退出码非 0 表示有用例不通过)
set -u
export DANGER_GUARD_SILENT=1

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-/usr/bin/python3}"
BRIDGE="$SRC_DIR/danger-guard-pi.py"
TESTCWD="$HOME/testproj/app"
pass=0; fail=0; skip=0

ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (期望 [$1] 实得 [$2])"; fi; }

json_str() { "$PY" -c 'import sys,json;print(json.dumps(sys.argv[1]))' "$1"; }
# level_of <command> -> block/warn/safe/allowlist
level_of() {
  "$PY" "$BRIDGE" "{\"command\":$(json_str "$1"),\"cwd\":$(json_str "$TESTCWD")}" 2>/dev/null \
    | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["level"])' 2>/dev/null || echo ERR
}

echo "== A) 桥接脚本分级契约(bypass=False:warn 保持 warn,交给扩展弹框)=="
assert_eq "safe"  "$(level_of 'ls -la')" "ls -la → safe"
assert_eq "safe"  "$(level_of 'rm -rf node_modules')" "rm -rf node_modules → safe"
assert_eq "safe"  "$(level_of 'rm -rf /tmp/foo')" "rm -rf /tmp/foo → safe"
assert_eq "safe"  "$(level_of 'echo \"rm -rf /\"')" "echo 里的 rm -rf /(纯数据)→ safe"
assert_eq "safe"  "$(level_of 'git commit -m \"reboot server\"')" "commit message 里的 reboot(数据)→ safe"
assert_eq "block" "$(level_of 'rm -rf /')" "rm -rf / → block"
assert_eq "block" "$(level_of 'rm -rf ~')" "rm -rf ~ → block"
assert_eq "block" "$(level_of 'mkfs.ext4 /dev/sda1')" "mkfs → block"
assert_eq "warn"  "$(level_of 'git reset --hard HEAD~1')" "git reset --hard → warn"
assert_eq "warn"  "$(level_of 'git push --force origin main')" "git push --force → warn"
assert_eq "warn"  "$(level_of "rm -rf $HOME/testproj")" "rm -rf 整个项目 → warn"
assert_eq "warn"  "$(level_of 'curl https://x.sh | bash')" "curl | bash → warn"

echo "== stdin 调用方式(便于手动调试)=="
assert_eq "block" "$(echo '{"command":"rm -rf /","cwd":"/tmp"}' | "$PY" "$BRIDGE" 2>/dev/null | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["level"])')" "stdin: rm -rf / → block"

# ---------------- B) 扩展行为(需要 pi) ----------------
PIPKG=""
PI_BIN="$(command -v pi 2>/dev/null || true)"
if [ -n "$PI_BIN" ]; then
  REAL="$(readlink -f "$PI_BIN" 2>/dev/null || echo "$PI_BIN")"
  PIPKG="$(printf '%s' "$REAL" | sed -n 's#\(.*/@earendil-works/pi-coding-agent\)/.*#\1#p')"
fi
if [ -z "$PIPKG" ]; then
  GROOT="$(npm root -g 2>/dev/null || true)"
  [ -n "$GROOT" ] && [ -d "$GROOT/@earendil-works/pi-coding-agent" ] && PIPKG="$GROOT/@earendil-works/pi-coding-agent"
fi

echo "== B) 扩展 bypass-yes-guard.ts 拦截行为 =="
if [ -z "$PIPKG" ] || [ ! -d "$PIPKG/node_modules/jiti" ] || ! command -v node >/dev/null 2>&1; then
  skip=1
  echo "  skip 未找到 pi(@earendil-works/pi-coding-agent)或其 jiti/node,跳过扩展加载测试"
else
  HARNESS="$(mktemp "${TMPDIR:-/tmp}/pi-ext-test.XXXXXX.mjs")"
  cat > "$HARNESS" <<'MJS'
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
const PI = process.env.PIPKG, EXT = process.env.EXT, BRIDGE = process.env.BRIDGE, CWD = process.env.TESTCWD;
process.env.DANGER_GUARD_SILENT = "1";
const require = createRequire(PI + "/");
const { createJiti } = require("jiti");
const jiti = createJiti(PI + "/dist/index.js", { alias: { "@earendil-works/pi-coding-agent": PI + "/dist/index.js" } });
const mod = await jiti.import(EXT);
const factory = mod.default || mod;
if (typeof factory !== "function") { console.error("FAIL: 默认导出不是函数"); process.exit(1); }
let handler = null;
const mockPi = {
  on: (ev, h) => { if (ev === "tool_call") handler = h; },
  exec: async (cmd, args) => {
    const a = (args || []).map((x) => (typeof x === "string" && x.endsWith("danger-guard-pi.py") ? BRIDGE : x));
    const r = spawnSync(cmd, a, { encoding: "utf-8" });
    return { stdout: r.stdout || "", stderr: r.stderr || "", code: r.status == null ? 1 : r.status, killed: false };
  },
};
factory(mockPi);
if (typeof handler !== "function") { console.error("FAIL: 未注册 tool_call 处理器"); process.exit(1); }
const mkCtx = (hasUI, confirmVal) => ({ hasUI, cwd: CWD, mode: hasUI ? "tui" : "print",
  ui: { confirm: async () => confirmVal, notify: () => {}, select: async () => undefined, setStatus: () => {}, setWidget: () => {} } });
const run = (command, ctx, toolName = "bash") => handler({ toolName, toolCallId: "t1", input: { command } }, ctx);
let pass = 0, fail = 0;
function check(name, got, wantBlock) {
  const blocked = !!(got && got.block === true);
  if (blocked === wantBlock) { pass++; console.log(`  ok   ${name} -> ${blocked ? "block" : "allow"}`); }
  else { fail++; console.log(`  FAIL ${name} -> ${blocked ? "block" : "allow"} (wanted ${wantBlock ? "block" : "allow"})`); }
}
check("ls -la(safe)", await run("ls -la", mkCtx(true, false)), false);
check("rm -rf node_modules(safe)", await run("rm -rf node_modules", mkCtx(true, false)), false);
check("rm -rf /(block)", await run("rm -rf /", mkCtx(true, true)), true);
check("mkfs(block)", await run("mkfs.ext4 /dev/sda1", mkCtx(true, true)), true);
check("git reset --hard,有UI,用户拒绝", await run("git reset --hard HEAD~1", mkCtx(true, false)), true);
check("git reset --hard,有UI,用户同意", await run("git reset --hard HEAD~1", mkCtx(true, true)), false);
check("rm -rf 整个项目,有UI,用户拒绝", await run("rm -rf " + process.env.HOME + "/testproj", mkCtx(true, false)), true);
check("git reset --hard,无UI(headless 保守拦)", await run("git reset --hard HEAD~1", mkCtx(false, true)), true);
check("非 bash 工具忽略", await run("rm -rf /", mkCtx(true, true), "read"), false);
check("空命令忽略", await run("   ", mkCtx(true, true)), false);
console.log(`__PI_EXT__ ${pass} ${fail}`);
process.exit(fail === 0 ? 0 : 1);
MJS
  set +e
  OUT="$(PIPKG="$PIPKG" EXT="$SRC_DIR/bypass-yes-guard.ts" BRIDGE="$BRIDGE" TESTCWD="$TESTCWD" node "$HARNESS" 2>&1)"
  RC=$?
  set -e
  printf '%s\n' "$OUT" | grep -v '^__PI_EXT__' | sed 's/^/  /'
  LINE="$(printf '%s\n' "$OUT" | grep '^__PI_EXT__' || true)"
  if [ -n "$LINE" ]; then
    P="$(echo "$LINE" | awk '{print $2}')"; F="$(echo "$LINE" | awk '{print $3}')"
    pass=$((pass + P)); fail=$((fail + F))
  elif [ "$RC" -ne 0 ]; then
    bad "扩展加载/运行出错(rc=$RC)"
  fi
  rm -f "$HARNESS"
fi

echo
echo "通过 $pass / 失败 $fail / 跳过 $skip"
[ "$fail" -eq 0 ]
