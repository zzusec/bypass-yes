# 命令守卫 · Claude Code / Codex / CodeBuddy

## yolo 让你不用点 Yes；守卫让你敢开 yolo

三家官方都有免确认开关：

| 客户端 | 官方 yolo 开关 |
|---|---|
| Claude Code | `--dangerously-skip-permissions` / `bypassPermissions` |
| Codex | `--dangerously-bypass-approvals-and-sandbox`（俗称 yolo） |
| CodeBuddy | `-y` / `bypassPermissions` |

它们解决的是同一件事：**别再弹窗了**。但代价是——**不看命令内容，一律放行**。

本项目不是 yolo 的替代品，而是**叠在 yolo 之上的一层兜底**：yolo 照开，
日常命令照样静默放行，只有危险的那几条被拦下、响铃、告诉你是哪条。

| 判定 | 例子 | 行为 |
|---|---|---|
| 安全（绝大多数） | `ls`、`npm run build`、`git status`、`rm -rf node_modules` | **静默放行**，一声不吭 |
| 危险 | `git reset --hard`、`npm publish`、`rm -rf ~/你的项目` | 响铃 + 命令行打出原因 + **拒绝** |
| 毁灭级 | `mkfs`、`rm -rf /`、`dd` 写物理盘 | 响铃 + **拒绝** |

---

## 一、为什么光开官方 yolo 不行

### 1. yolo 眼里没有「危险命令」

同一句需求「清理构建产物重新构建」，AI 把路径写错了：

**只开官方 yolo：**

```
$ rm -rf ~/my-app          ← 本想删 dist，写成了项目根
（执行完毕，没有任何提示，项目没了）
```

**yolo + 守卫：**

```
$ rm -rf dist              → 放行，一声不吭
$ rm -rf ~/my-app          → 拒绝

[命令守卫] 已拦截:rm -rf 删除整个项目/系统路径或目标不明
  rm -rf ~/my-app
  要执行就自己跑,或把命令写进 allowlist.txt
（同时响铃）
```

差别不在「拦得多」，而在**只有那一条危险命令被拦**——`rm -rf dist` 照常放行，AI 的活一点没被打断。

### 2. 逐条看：yolo 放行的都是些什么

| 命令 | 官方 yolo | 会怎样 | 守卫 |
|---|---|---|---|
| `ls`、`npm run build`、`git status` | 执行 | — | 放行（不打断） |
| `rm -rf node_modules` / `dist` | 执行 | — | 放行（目标分级为普通目录） |
| `rm -rf ~/你的项目` | **执行** | 项目没了，连个提示都没有 | **拒绝** + 响铃 |
| `git reset --hard` | **执行** | 未提交改动全丢 | **拒绝** |
| `git push --force` | **执行** | 远程历史被改，同事拉不到代码 | **拒绝** |
| `curl x.sh \| bash` | **执行** | 陌生远程代码直接跑起来 | **拒绝** |
| `npm publish` | **执行** | 源码公网可见、版本号被永久占用 | **拒绝** |
| `crontab -r` | **执行** | 定时任务整表清空，无备份 | **拒绝** |
| `mkfs`、`rm -rf /` | **执行** | 盘没了 | **拒绝** |
| 出事之后 | 静默 | 你根本不知道发生了什么 | 响铃 + 命令行打出原因 |

### 3. 官方的静态 deny 也顶不上

Claude / CodeBuddy 自带的 `permissions.deny` 只能按命令前缀硬拦，粒度太粗：

- `Bash(rm -rf /*)` 里的 `*` **跨 `/` 匹配**——它拦的不是「根目录」，而是**所有绝对路径**，
  连 `rm -rf /tmp/xxx`、项目里的 `node_modules` 一起拦死
- `Bash(rm *)`、`Bash(sudo *)` 这类更是天天误伤
- 「删整个项目要拦、删 `node_modules` 要放行」这种需求，静态规则根本表达不出来

守卫按**删除目标**分级，所以能同时做到这两件事：

| 删除目标 | 判定 |
|---|---|
| `node_modules`、`dist`、`build`、项目内子目录 | 放行 |
| `/tmp/…`、`/private/tmp/…`（含里面的 git clone） | 放行 |
| 家目录直接子项、git 仓库根、当前所在目录（= 整个项目） | 拒绝 |
| `/etc`、`/opt` 等系统路径 | 拒绝 |
| `/`、`~`、`/Users/xxx`、一级系统目录 | 拒绝 |

### 4. 一句话

> **yolo 负责「别烦我」，守卫负责「别出事」。**
> 只开 yolo = 拆了刹车；yolo + 守卫 = 刹车还在，只是不用每次都踩。

---

## 二、它是怎么判的

- **按命令内容分级**，不是按工具名一刀切（见上面三档表）
- **只匹配命令，不匹配数据**：`echo "rm -rf /"`、`psql -c "DELETE FROM t"`、
  `git commit -m "remove reboot logic"` 都是引号里的数据，不拦
- **但会补扫要真执行的代码**：`bash -c "…"`、`eval "…"` 里的内容照查，藏这里也拦得住
- **客户端 wrapper 会被拆开看**：Bash 工具实际执行的是
  `zsh -c '<shell snapshot> && eval "你的命令"'`，守卫取内层判定，不会因为外层语法不完整
  就把整条判成危险（曾导致**所有 `rm -rf` 都被拦**，连 `node_modules` 都删不掉）
- **被拦时不弹系统窗口**，只在你跑 CLI 的那个终端里打一行原因 + 响铃
- **规则只有一份**：改 `rules.py` 一处，三家同时生效

```
rules.py               危险命令唯一真源
core.py                判定引擎
danger-guard.py        Claude Code / CodeBuddy 入口（两家 hook 协议完全一致）
danger-guard-codex.py  Codex 入口
```

> 一个实测结论：yolo 模式下客户端会**吞掉**守卫的「弹确认」，
> 实测 `git reset --hard` 直接执行、改动丢失，而同一环境下 `deny` 的命令能被拦住。
> 所以这类模式下危险档是**拒绝**而不是「弹确认」——弹不出来就别假装能弹。

---

## 三、还顺手解决了这些

1. **yolo 管不到的弹窗** —— 这些跟命令危不危险无关，纯开 yolo 照样弹，`install*.sh` 都配好了：

   | 弹窗 | 出处 | 处理 |
   |---|---|---|
   | `Yes, and allow access to tmp/ and similar commands` | Claude 的 Bash 沙箱文件隔离层 | `sandbox.filesystem.disabled = true`（网络隔离保留） |
   | `don't ask again for … commands in <目录>` | Claude 的 auto 模式分类器 | `permissions.disableAutoMode = "disable"` |
   | `Allow the … MCP server to run tool …` | Codex 的 MCP 工具审批 | `mcp_servers.*.default_tools_approval_mode = "approve"` |
   | HIGH/CRITICAL 级命令仍问一次 | CodeBuddy 自带的高危审批 | 无解，hook 和 `deny` 都压不住 |

2. **三家的规则不用写三遍** —— 一份 `rules.py`，Codex 的 `.rules` 和 Claude/CodeBuddy 的
   `deny` 都从它生成，还带一致性校验（改了规则忘了同步会直接报错）。
3. **Codex 可以不用关沙箱** —— `--dangerously-bypass-approvals-and-sandbox` 是连沙箱一起关；
   用守卫可以保留 `-s workspace-write`，只放行安全命令。

---

## 四、安装

### 三家一起装（推荐）

```bash
git clone https://github.com/zzusec/claude-codex-bypass-yes.git
cd claude-codex-bypass-yes
bash install-all.sh
```

一条命令装完三家，Claude / CodeBuddy 顺带配成 bypass 模式。
只想装守卫、不动权限模式：`bash install-all.sh --no-bypass`。

装完：**重启三个客户端**；Codex 还要在会话里执行 `/hooks`，把 PreToolUse、
PermissionRequest 两条 danger-guard **Trust** 一次（没 Trust 时钩子会静默不执行）。

### 为什么还留着三个单独的脚本

三家的配置落点完全不一样，没法共用一份：

| 客户端 | 配置落在哪 | 额外动作 |
|---|---|---|
| Claude Code | `~/.claude/settings.json`（permissions + hooks，JSON） | 无 |
| CodeBuddy | `~/.codebuddy/settings.json`（结构同 Claude） | 无 |
| Codex | `~/.codex/hooks.json` + `config.toml`（TOML）+ `rules/*.rules` | 必须 `/hooks` Trust 一次 |

只装其中一个就跑对应的脚本：

```bash
bash install.sh --bypass      # Claude Code
bash install-codex.sh         # Codex（≥ 0.142）
bash install-codebuddy.sh     # CodeBuddy
```

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

想确认 Codex 真的在调用钩子：

```bash
codex exec -s workspace-write "执行命令 mkfs.ext4 --help 并原样报告输出"
```

macOS 没有 `mkfs`，放行也无害；输出里出现 `Command blocked by PreToolUse hook:` 即已生效。

### 装完后可选的调整

| 想干嘛 | 怎么做 |
|---|---|
| 某类危险命令不想再拦 | `echo '^\s*git\s+reset\s+--hard\b' >> ~/.claude/hooks/allowlist.txt`（三家共享，毁灭级兜底仍拦） |
| 改危险命令清单 | 编辑 `~/.claude/hooks/rules.py`，然后重跑 install 脚本 |
| 终端提示被 TUI 盖掉看不见 | `rules.py` 里 `NOTIFY_CENTER = True`，会再发一条通知中心横幅（不抢焦点） |
| 关掉响铃 / 调音量 | 环境变量 `DANGER_GUARD_SILENT=1`；音量在 `core.py` 的 `SOUND_VOLUME` |

---

## 五、升级

```bash
cd claude-codex-bypass-yes
git pull
bash install-all.sh             # 三家一起装的话，跑这一条就够
# 或按需单独跑：
bash install.sh --bypass        # Claude Code
bash install-codex.sh           # Codex
bash install-codebuddy.sh       # CodeBuddy
```

脚本是幂等的，会先备份再改；`rules.py` 和 `core.py` 每次都一起复制过去，不会出现
「脚本新、规则旧」。装完重启对应客户端，Codex 若 `hooks.json` 有变化需再 `/hooks` Trust 一次。

---

## 六、卸载

```bash
# Claude Code：删掉 settings.json 里指向 danger-guard.py 的 PreToolUse 条目
#             （settings.local.json 里同步过的话也删）
rm -rf ~/.claude/hooks

# CodeBuddy：删掉 ~/.codebuddy/settings.json 里的 PreToolUse 条目
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
