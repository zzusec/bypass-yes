# Claude Code / Codex / CodeBuddy 命令守卫

**主要作用：除危险命令外一律自动允许，减少反复点 Yes。**

给 Claude Code / Codex / CodeBuddy 加一层本地判断（仅 macOS），三家共用同一份规则库：

- 日常命令（`ls`、`git status`、`npm run`、装包、查日志…）→ **直接放行，不弹确认**
- 危险命令（`rm -rf …`、`git reset --hard`、`git push --force`…）→ **响铃 + 命令行提示 + 拒绝**（只有客户端弹得了确认时才是弹确认，见下文）
- 毁灭级（`rm -rf /`、`mkfs`、`dd` 写盘…）→ **响铃 + 直接拒绝**

`rm -rf` 按删除目标分级，**删普通目录不弹确认**：

- **直接放行**：项目内子目录/文件（`node_modules`、`dist`、`build`…）、临时目录（`/tmp/…`、`/private/tmp/…`）、家目录下两层以上的深层路径
- **拒绝 / 弹确认**（取决于客户端弹不弹得了确认，见下文）：「整个项目」级——git 仓库根、家目录直接子项（`~/xxx`）、当前所在目录（`.`/`..`/cwd 及其祖先）；系统路径（`/opt/…` 等）；以及变量、通配符、命令替换等看不清目标的写法（保守回落）
- **直接拒绝**：根目录、家目录、整个用户目录（`/Users/xxx`）、一级系统目录（`/etc`、`/usr`、`/tmp` 整删…）

命令替换（`$(…)` / 反引号）只连累**沾到它的那个目标**：`B=$(osascript …); rm -rf ~/Downloads/x.app` 里的 `rm` 照常按真实路径放行，只有 `rm -rf $(cat t)`、`D=$(pwd); rm -rf $D` 这种目标本身说不清的才弹确认。

组合命令里其它危险段（如 `rm -rf /tmp/x && git push --force`）照常拦。

目标体验：AI 能自己干活，你不用一直点 Yes；真正危险时才拦一下。

---

## 架构：一份规则库，三个入口

危险命令只要在 `rules.py` 里维护一次，三家同时生效：

```
rules.py              唯一真源:BLOCK / WARN / PASSTHROUGH / rm 分级 / 各家产物的派生表
core.py               判定引擎:classify(cmd, cwd) -> (block|warn|allowlist|safe|passthrough)
danger-guard.py        入口·Claude Code 与 CodeBuddy(两家 hook 协议完全一致)
danger-guard-codex.py  入口·Codex(只认 deny,另有 PermissionRequest 事件)
gen_codex_rules.py     从 rules.py 生成 Codex 的 .rules(带一致性校验)
```

三家的差别只在「把等级翻译成什么输出」，判定逻辑不重复：

| | block(毁灭级) | warn(危险) | 其余 |
|---|---|---|---|
| Claude Code | 响铃 + 命令行提示 + `deny` | 响铃 + `ask`(只有非 bypass 走得到) | 静默放行 |
| CodeBuddy | 同上(协议一致) | 同上 | 同上 |
| Codex | 响铃 + 命令行提示 + `deny` | 响铃 + 静默,交给 `.rules` 的 prompt / 沙箱提权(`approval_policy` 非 never 时) | 静默放行 |

两份派生产物也从 `rules.py` 生成,不用手工同步:

- `~/.codex/rules/danger-guard.rules` ← `gen_codex_rules.py`(Codex hook 不支持 ask,确认档只能写在这里)
- Claude / CodeBuddy 的 `permissions.deny` ← `install*.sh` 读 `rules.CLAUDE_DENY`

`gen_codex_rules.py` 会校验每条 Codex 规则的 `source_reason` 确实存在于 `rules.py`;
改了规则库文案却忘了同步 → 直接报错,不会静默漂移:

```bash
/usr/bin/python3 gen_codex_rules.py --check
```

---

## 危险命令被拦时会发生什么

`bypassPermissions` 会吞掉守卫的 ask(实测:`git reset --hard` 直接执行,未提交改动就没了)。
所以 WARN 档在 bypass 下一律按 deny 处理,并**响铃 + 在命令行打出被拦原因**:

```
[命令守卫] 已拦截:git reset --hard 丢弃改动
  git reset --hard
  要执行就自己跑,或把命令写进 allowlist.txt
```

- 提示写到你跑 Claude / CodeBuddy 的那个终端,同时响铃
- **不等输入** —— TUI 自己也在读同一个终端,hook 抢不到按键(实测读到 EOF),
  干等只会把 AI 卡住几十秒再拒绝,体验比直接拒绝更差
- 想放行:自己敲,或把命令写进 `allowlist.txt`(白名单优先于 WARN)
- 终端提示可能被 TUI 重绘盖掉 → 把 `rules.NOTIFY_CENTER` 设成 `True`,
  会再发一条 macOS 通知中心横幅(不带按钮、不抢焦点)

相关配置:

| 项 | 位置 | 说明 |
|---|---|---|
| `BYPASS_DENY_ALL_WARN` | `rules.py`,默认 `True` | bypass 下整个 WARN 档硬拒。关成 `False` 则只在 `BYPASS_DENY_REASONS` 里的才硬拒,其余退回客户端 ask(bypass 下会被吞 = 放行) |
| `NOTIFY_CENTER` | `rules.py`,默认 `False` | 开一条 macOS 通知中心横幅 |
| `DANGER_GUARD_ASK=0` | 环境变量 | 连终端提示也不打(回归测试用) |
| `DANGER_GUARD_SILENT=1` | 环境变量 | 关掉响铃 |

三家的「不弹确认」怎么判定 —— `core.is_bypass_mode()` 自动识别,不用配:

| 客户端 | 判定依据 |
|---|---|
| Claude Code | `~/.claude/settings.json` → `permissions.defaultMode == "bypassPermissions"` |
| CodeBuddy | `~/.codebuddy/settings.json` → 同上 |
| Codex | `~/.codex/config.toml` → `approval_policy = "never"` |

任一成立 → WARN 档一律硬拒 + 命令行提示;不成立 → 维持各自的确认通道
(客户端自己的 ask / Codex 的 `.rules` prompt 与沙箱提权)。

---

## Claude Code

### 安装

```bash
git clone https://github.com/zzusec/claude-codex-bypass-yes.git
cd claude-codex-bypass-yes
bash install.sh --bypass
```

- `install.sh --bypass`：装钩子 + 尽量少弹无用确认（推荐）
- 装完**重启 Claude Code**

### 验证

```bash
# 安全命令：应无输出（静默=放行；勿输出 allow，auto 模式会报 unsupported）
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | /usr/bin/python3 ~/.claude/hooks/danger-guard.py

# 危险命令：bypass 下应响铃 + 命令行提示，并输出 permissionDecision: "deny"
# （rm -rf /tmp/x 属于普通目录，是放行的，别拿它当危险用例）
echo '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}' \
  | /usr/bin/python3 ~/.claude/hooks/danger-guard.py

bash test.sh
```

### 升级

```bash
cd claude-codex-bypass-yes
git pull
bash install.sh --bypass
```

重启 Claude Code。

---

## Codex CLI

需要 Codex CLI ≥ 0.142（0.142.5 / 0.145.0 实测）。

### 安装

```bash
git clone https://github.com/zzusec/claude-codex-bypass-yes.git
cd claude-codex-bypass-yes
bash install-codex.sh
```

装完在 Codex 输入 `/hooks`，把 **PreToolUse**、**PermissionRequest** 两条 danger-guard **Trust** 一次。

### 验证

```bash
# 安全命令：应无输出（静默=放行）
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | /usr/bin/python3 ~/.codex/hooks/danger-guard-codex.py PreToolUse

# 毁灭级：应响铃 + permissionDecision: "deny"
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
  | /usr/bin/python3 ~/.codex/hooks/danger-guard-codex.py PreToolUse

bash test-codex.sh
```

上面只验证脚本本身。要确认 **Codex 真的在调用钩子**（未 Trust 时 hooks 会静默不执行，看不出区别），跑一次端到端：

```bash
codex exec -s workspace-write "执行命令 mkfs.ext4 --help 并原样报告输出"
```

> `--full-auto` 自 codex-cli 0.147.0 起已移除，等价写法是 `-s workspace-write`；非 git 目录还需加 `--skip-git-repo-check`。

macOS 没有 `mkfs`，放行也无害。输出里出现下面两行即已生效：

```
hook: PreToolUse Blocked
Command blocked by PreToolUse hook: [命令守卫] mkfs 格式化文件系统
```

只出现 `hook: PreToolUse` / `Completed` 而命令照跑，说明还没 Trust（临时可加 `--dangerously-bypass-hook-trust`）。也可以查 `~/.codex/config.toml` 的 `[hooks.state]`，两条都应有 `trusted_hash` + `enabled = true`。

### 本守卫不管 MCP 工具弹窗

`hooks.json` 的 matcher 是 `"Bash"`，只拦 shell 命令。MCP 工具调用（如 `Allow the chrome-devtools MCP server to run tool "navigate_page"?`）走 Codex 自带的审批，守卫看不到，别往钩子上查。免弹窗在 `~/.codex/config.toml` 配：

```toml
[mcp_servers.chrome-devtools]
default_tools_approval_mode = "approve"   # auto | prompt | writes | approve
```

- 单个工具粒度：`[mcp_servers.<name>.tools.<tool>] approval_mode = "approve"`；也可用 `enabled_tools` / `disabled_tools` 收窄暴露面。
- 等效做法：弹窗时按 `3. Always allow`，Codex 会把同样的配置写进 `config.toml`。
- 改完要**重启 Codex TUI**；弹窗只出现在 TUI，`codex exec`（approval=never）本来就不弹，所以这项改动没法用 exec 验证。
- 忘了合法取值就故意填错让它报出来：`codex mcp list -c 'mcp_servers.x.default_tools_approval_mode="bogus"'`。

### 升级

```bash
cd claude-codex-bypass-yes
git pull
bash install-codex.sh
```

`hooks.json` 有变时，再 `/hooks` Trust 一次。

---

## CodeBuddy Code

CodeBuddy 的 hook 协议与 Claude Code 完全一致(同样读 `hookSpecificOutput.permissionDecision`
的 deny / ask,事件名同为 `PreToolUse`,输入 JSON 同构),所以直接复用 `danger-guard.py`,
连 `core.py`、`rules.py` 都是同一份。

### 安装

```bash
bash install-codebuddy.sh
```

装完**重启 CodeBuddy**。

### 验证

```bash
# 毁灭级:应输出 permissionDecision: "deny"
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
  | /usr/bin/python3 ~/.codebuddy/hooks/danger-guard.py
```

### 守卫管不到的部分

`-y` / `bypassPermissions` 下 **HIGH/CRITICAL 级命令仍会问一次** —— 这是 CodeBuddy 自身
的高危审批,hook 和 `deny` 都压不住。

---

## 上下文到 80% 自动压缩

上下文用到 80% 就自动 compact，不用等它快撑爆再手忙脚乱敲 `/compact`。两端用的都是官方原生能力，这里只做幂等配置：

| | 落点 | 效果 |
|---|---|---|
| Claude Code | `~/.claude/settings.json` → `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` + `autoCompactEnabled` | 阈值 = `min(窗口 × 80%, 窗口 − 13000)` |
| Codex CLI | `~/.codex/config.toml` → `model_auto_compact_token_limit` | 阈值 = 窗口 × 80%（按 `model_context_window` 换算） |

`install.sh` / `install-codex.sh` 已默认带上（`--no-autocompact` 可跳过，`--autocompact-pct 75` 改阈值）。也可以单独跑：

```bash
bash autocompact.sh                  # Claude + Codex，80%
bash autocompact.sh --pct 75         # 改阈值
bash autocompact.sh --claude-only    # 或 --codex-only
bash autocompact.sh --verify         # 只看当前生效值
bash autocompact.sh --uninstall      # 撤销
```

改完**重启** Claude Code / Codex 生效。自测：`bash test-autocompact.sh`。

Codex 的阈值是绝对 token 数，`config.toml` 里没写 `model_context_window` 时没法换算百分比，脚本会提示跳过，按提示补一个窗口即可：

```bash
bash autocompact.sh --codex-only --codex-window 272000
```

> 注意区分：`~/.claude/hooks/context-guard.py` 那种「近 3 天有 N 个超大会话(>8MB)」提示说的是**磁盘上会话文件的体积**，跟当前上下文百分比是两回事，不是本功能没生效。

---

## deny 里的 `*` 会跨 `/`，别写「只拦根目录」的假规则

`permissions.deny` 优先级最高，`bypassPermissions` 也压不住，命中就直接 `Permission to use Bash ... has been denied`。而它的 `*` 是跨 `/` 匹配的：

- `Bash(rm -rf /*)` —— 不是「只拦根目录」，而是拦下**所有绝对路径**的 `rm -rf`，连 `/tmp/xxx`、项目里的 `node_modules` 一起拦
- `Bash(rm -rf ~*)` / `Bash(rm -rf /Users/*)` 同理，等于家目录下什么都删不了
- `Bash(rm -rf *)`、`Bash(sudo *)`、`Bash(git reset --hard *)` 这类更是天天误伤

`install.sh --bypass` 会自动把这些过宽条目剔除，只留精确的毁灭级硬闸（`rm -rf /`、`rm -rf ~`、`rm -rf /Users`、`mkfs *`、`dd if=* of=/dev/*`），路径分级交回 danger-guard：临时目录/项目内子目录静默放行，整个项目响铃后拒绝（非 bypass 时弹确认），根/家/整盘直接拒绝。

---

## 已经 bypass 了，还弹「This command requires approval」

选项里带一句 `Yes, and allow access to tmp/ and similar commands` 的，不是权限问题，是 **Bash 沙箱的文件隔离层**：命令要写沙箱外的路径（`/tmp`、项目目录），沙箱另外要一次审批，`bypassPermissions` 管不到它。

`install.sh --bypass` 会一并关掉文件隔离层，网络隔离保留：

```json
"sandbox": { "filesystem": { "disabled": true } }
```

改完要重启 `claude`（沙箱在启动时初始化）。想连网络出口一起放开就写 `"sandbox": { "enabled": false }`。

### 选项 2 是「don't ask again for … commands in <目录>」= 当前会话在 auto 模式

这一种跟沙箱无关：**auto 模式**由分类器逐条判断，`ssh` 到远程执行、没见过的 CLI 照样弹，`permissions.allow` 也压不住。权限模式是**每个会话**的，shift+tab 一循环就可能从 bypass 滑进 auto。

```json
"permissions": { "defaultMode": "bypassPermissions", "disableAutoMode": "disable" }
```

`install.sh --bypass` 会一起写上，shift+tab 从此不经过 auto。已经在 auto 里的旧会话，shift+tab 切回 bypass 即可。

排查顺序：先看弹窗第 2 个选项的措辞——带 `allow access to tmp/` 是沙箱，带 `don't ask again for … in <目录>` 是 auto 模式。守卫拦的**不弹窗**，只在命令行打一行 `[命令守卫] 已拦截:…` 并响铃。

---

## 可选：某类危险命令也不想确认

```bash
echo '^\s*git\s+restore\b' >> ~/.claude/hooks/allowlist.txt
```

毁灭级（`rm -rf /`、`mkfs`、`dd` 写盘）不能白名单放行。

白名单写 `~/.claude/hooks/allowlist.txt` 一份就够——`core.py` 会同时读本客户端的和这一份，三家共享。

提示音默认是系统音量的一半（`core.py` 里的 `SOUND_VOLUME = "0.5"`）；要再调改这个值（0~1，相对系统音量）。

---

## 卸载

- Claude：删掉 `~/.claude/settings.json` 里指向 `danger-guard.py` 的 hooks
- CodeBuddy：删掉 `~/.codebuddy/settings.json` 里指向 `danger-guard.py` 的 hooks
- Codex：删掉 `~/.codex/hooks.json` 相关条目，以及 `~/.codex/rules/danger-guard.rules`

## 许可

MIT

## 致谢

感谢 [linuxdo](https://linux.do/) 社区的讨论、分享与反馈。
