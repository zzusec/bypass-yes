# 命令守卫 · Claude Code / Codex / CodeBuddy

**一句话：让 AI 自己干活，不用一直点 Yes；真遇到危险命令，响铃 + 拒绝，而不是闷头执行。**

一个本地命令分级器，挂在三家 AI CLI 的 Bash 工具上（仅 macOS）：

| 判定 | 例子 | 行为 |
|---|---|---|
| 安全 | `ls`、`npm run build`、`git status`、`rm -rf node_modules` | **静默放行**，一声不吭 |
| 危险 | `git reset --hard`、`npm publish`、`rm -rf ~/你的项目` | 响铃 + 命令行打出原因 + **拒绝** |
| 毁灭级 | `mkfs`、`rm -rf /`、`dd` 写物理盘 | 响铃 + **拒绝** |

> 危险档在客户端弹得了确认时是**弹确认**，弹不了时（yolo 模式）才是直接拒绝。原因见第一节。

三家共用同一份规则库，改一处三家生效：

```
rules.py               危险命令唯一真源
core.py                判定引擎
danger-guard.py        Claude Code / CodeBuddy 入口（两家 hook 协议完全一致）
danger-guard-codex.py  Codex 入口
```

---

## 一、和 yolo 比，强在哪

三家各有「一把梭」的开关：

| 客户端 | 免确认开关 |
|---|---|
| Claude Code | `--dangerously-skip-permissions` / `bypassPermissions` |
| Codex | `--dangerously-bypass-approvals-and-sandbox`（也就是 yolo）/ `approval_policy = "never"` |
| CodeBuddy | `-y` / `bypassPermissions` |

它们的共同点是：**不看命令内容，一律放行**。本守卫按命令内容分级：

| 命令 | yolo 三件套 | 本守卫 |
|---|---|---|
| `ls`、`npm run build`、`git status` | 执行 | 静默放行 |
| `rm -rf node_modules` | 执行 | 静默放行（目标分级为普通目录） |
| `rm -rf ~/你的项目` | **执行** | 拒绝 |
| `git reset --hard` | **执行**（未提交改动直接丢） | 拒绝 |
| `npm publish`、`crontab -r` | **执行** | 拒绝 |
| `mkfs`、`rm -rf /` | **执行** | 拒绝 |
| 出事时 | 静默，你不知道发生了什么 | 响铃 + 命令行打出被拦原因 |

### 守卫不是「yolo + 弹窗」——开了 yolo，弹窗就没了

这是最容易误解的一点。yolo 模式下客户端会**吞掉**守卫的 ask：

> 实测：让 AI 执行 `git reset --hard`，bypass 模式下直接执行了，未提交的改动没了；
> 同一环境下守卫返回 `deny` 的命令（`mkfs`）却能被拦住。

所以在这类模式下，危险档从「弹确认」改成「拒绝 + 提示」——反正弹不出来，就别假装能弹。
`core.is_bypass_mode()` 自动识别三家各自的写法，不用你配：

| 客户端 | 「不弹确认」的判定依据 |
|---|---|
| Claude Code | `~/.claude/settings.json` → `permissions.defaultMode == "bypassPermissions"` |
| CodeBuddy | `~/.codebuddy/settings.json` → 同上 |
| Codex | `~/.codex/config.toml` → `approval_policy = "never"` |

### yolo 管不到的弹窗，这里都配好了

下面这些跟命令危不危险无关，是客户端自己的机制，纯开 yolo 照样弹：

| 弹窗 | 出处 | 处理 |
|---|---|---|
| `Yes, and allow access to tmp/ and similar commands` | Claude 的 Bash 沙箱文件隔离层 | `sandbox.filesystem.disabled = true`（网络隔离保留） |
| `don't ask again for … commands in <目录>` | Claude 的 auto 模式分类器 | `permissions.disableAutoMode = "disable"` |
| `Allow the chrome-devtools MCP server to run tool …` | Codex 的 MCP 工具审批 | `mcp_servers.*.default_tools_approval_mode = "approve"` |
| HIGH/CRITICAL 级命令仍问一次 | CodeBuddy 自带的高危审批 | 无解，hook 和 `deny` 都压不住 |

另外 Codex 的 `--dangerously-bypass-approvals-and-sandbox` 是**连沙箱一起关**；用本守卫
可以保留 `-s workspace-write` 的沙箱，只放行安全命令，安全性高一档。

---

## 二、主要解决什么问题

1. **弹窗疲劳** —— 一个项目跑下来要点几十次 Yes，最后变成无脑回车。
2. **全放行又怕出事** —— 开了 yolo，`rm -rf ~/项目`、`npm publish`、`git reset --hard` 全都闷头执行。
3. **`rm -rf` 一刀切的尴尬** —— 静态 deny 要么全拦（连 `node_modules` 都删不掉），要么全放。
   守卫按**删除目标**分级：项目内子目录和 `/tmp` 放行，整个项目/系统路径拒绝，根、家目录、整盘直接拒。
4. **三家的规则要写三遍** —— 现在一份 `rules.py`，Codex 的 `.rules` 和 Claude/CodeBuddy 的
   `deny` 都从它生成，还带一致性校验（改了规则忘了同步会直接报错，不会静默漂移）。
5. **引号里的数据被误伤** —— `echo "rm -rf /"`、`psql -c "DELETE FROM t"`、
   `git commit -m "remove reboot logic"` 都只是数据，不该拦。
6. **客户端 wrapper 被误判** —— Bash 工具真正执行的是
   `zsh -c '<shell snapshot> && eval "你的命令"'`，守卫会拆开看内层，不会因为它语法不完整
   就把整条判成危险（曾导致**所有 `rm -rf` 都被拦**，连 `node_modules` 都删不掉）。

---

## 三、安装

### Claude Code

```bash
git clone https://github.com/zzusec/claude-codex-bypass-yes.git
cd claude-codex-bypass-yes
bash install.sh --bypass
```

装完**重启 Claude Code**。`--bypass` 会一并配好：默认 `bypassPermissions`、
关掉沙箱文件隔离层、禁掉 auto 模式，以及从规则库生成的精确 `deny`
（只拦毁灭级，不会误伤 `/tmp` 和 `node_modules`）。

### Codex CLI

需要 Codex CLI ≥ 0.142。

```bash
bash install-codex.sh
```

装完在 Codex 里执行 `/hooks`，把 **PreToolUse**、**PermissionRequest** 两条 danger-guard
**Trust** 一次，然后重启。

### CodeBuddy Code

```bash
bash install-codebuddy.sh
```

装完**重启 CodeBuddy**。它的 hook 协议与 Claude Code 完全一致，所以入口脚本和规则库都是同一份。

### 验证

```bash
# 安全命令：无输出（静默 = 放行）
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | /usr/bin/python3 ~/.claude/hooks/danger-guard.py

# 危险命令：响铃 + 命令行提示 + permissionDecision: "deny"
echo '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}' \
  | /usr/bin/python3 ~/.claude/hooks/danger-guard.py

# Codex 版（多一个事件参数）
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
  | /usr/bin/python3 ~/.codex/hooks/danger-guard-codex.py PreToolUse
```

回归测试：`bash test.sh`（100 条）、`bash test-codex.sh`（57 条）。

想确认 Codex 真的在调用钩子（未 Trust 时会静默不执行，看不出区别）：

```bash
codex exec -s workspace-write "执行命令 mkfs.ext4 --help 并原样报告输出"
```

macOS 没有 `mkfs`，放行也无害。输出里出现 `Command blocked by PreToolUse hook:` 即已生效。

### 装完后可选的调整

| 想干嘛 | 怎么做 |
|---|---|
| 某类危险命令不想再拦 | `echo '^\s*git\s+reset\s+--hard\b' >> ~/.claude/hooks/allowlist.txt`（三家共享，毁灭级兜底仍拦） |
| 改危险命令清单 | 编辑 `~/.claude/hooks/rules.py`，然后重跑对应的 install 脚本 |
| 终端提示被 TUI 盖掉看不见 | `rules.py` 里 `NOTIFY_CENTER = True`，会再发一条通知中心横幅（不抢焦点） |
| 关掉响铃 / 调音量 | 环境变量 `DANGER_GUARD_SILENT=1`；音量在 `core.py` 的 `SOUND_VOLUME` |
| 只装守卫，不要 yolo | install 时不加 `--bypass`（危险档就退回弹确认） |

---

## 四、升级

```bash
cd claude-codex-bypass-yes
git pull
bash install.sh --bypass        # Claude Code
bash install-codex.sh           # Codex
bash install-codebuddy.sh       # CodeBuddy
```

装了哪个就重跑哪个。脚本是幂等的，会先备份再改；`rules.py` 和 `core.py` 每次都一起复制过去，
不会出现「脚本新、规则旧」。装完重启对应客户端；Codex 若 `hooks.json` 有变化，需要再 `/hooks` Trust 一次。

---

## 五、卸载

```bash
# Claude Code：删掉 settings.json 里指向 danger-guard.py 的 PreToolUse 条目
#             （settings.local.json 里同步过的话也删）
rm -rf ~/.claude/hooks

# CodeBuddy：删掉 ~/.codebuddy/settings.json 里指向 danger-guard.py 的 PreToolUse 条目
rm -rf ~/.codebuddy/hooks

# Codex：删掉 ~/.codex/hooks.json 里的相关条目
rm -rf ~/.codex/hooks ~/.codex/rules/danger-guard.rules
```

`install*.sh` 每次运行都会留一份 `settings.json.bak.cmdguard` / `hooks.json.bak.cmdguard`
备份，想还原直接拷回去。权限模式（`defaultMode`、`disableAutoMode`、`sandbox`）也是 install
写进去的，拷回备份即可一并还原。

---

## 许可

MIT

## 致谢

感谢 [linuxdo](https://linux.do/) 社区的讨论、分享与反馈。
