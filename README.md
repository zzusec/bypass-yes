# bypass-yes · 命令守卫

**Claude Code / Codex / CodeBuddy / zcode / pi 五家通用。**

**yolo 让你不用点 Yes；守卫让你敢开 yolo。**

## 和官方 yolo 的区别

五家官方都有「免确认」姿态——Claude `--dangerously-skip-permissions`、
Codex `--dangerously-bypass-approvals-and-sandbox`（俗称 yolo）、CodeBuddy `-y`、
zcode `--mode yolo`、pi 干脆没有沙箱也不审批任何命令（等于一直 yolo）。
它们**不看命令内容，一律放行**。

守卫不是替代品，是**叠在 yolo 上面的一层**（install 会把 yolo 一起开好）：

| | 只开官方 yolo | 装上守卫 |
|---|---|---|
| **日常命令** `ls`、`npm run build` | 放行 | 放行 |
| **删构建产物** `rm -rf node_modules` | 放行 | 放行 |
| **删整个项目** `rm -rf ~/你的项目` | 删除 | **拦下** + 响铃 |
| **回滚改动** `git reset --hard` | 重置 | **拦下** + 响铃 |
| **强推** `git push --force` | 推送 | **拦下** + 响铃 |
| **执行远程脚本** `curl x.sh \| bash` | 执行 | **拦下** + 响铃 |
| **发布包** `npm publish` | 发布 | **拦下** + 响铃 |
| **清空定时任务** `crontab -r` | 清空 | **拦下** + 响铃 |
| **格式化磁盘** `mkfs`、`rm -rf /` | 格式化 | **拦下** + 响铃 |
| **出事之后** | 静默 | 终端告知 + 响铃 |

> **一句话：yolo 负责「别烦我」，守卫负责「别出事」——两个一起开，才敢让 AI 自己跑。**

守卫按**删除目标**分级（项目内子目录和 `/tmp` 放行，整个项目/家目录/根拦下）；
官方 `permissions.deny` 只有命令前缀、`*` 还跨 `/` 匹配，做不到这种粒度。
另外只匹配命令不匹配数据（`echo "rm -rf /"` 不拦），`eval` / `bash -c` 会补扫。

五家共用同一套判定引擎（`core.py`）和规则库（`rules.py`，唯一真源），
只是各家协议不同，由不同入口脚本翻译输出：

| 客户端 | 拦截机制 | 入口 | 配置落点 |
|---|---|---|---|
| Claude Code | PreToolUse hook | `danger-guard.py` | `~/.claude/settings.json` |
| CodeBuddy | PreToolUse hook（同 Claude 协议） | `danger-guard.py` | `~/.codebuddy/settings.json` |
| zcode | PreToolUse hook（同 Claude 协议） | `danger-guard.py` | `~/.zcode/cli/setting.json` |
| Codex CLI | hooks.json + `.rules` | `danger-guard-codex.py` | `~/.codex/` |
| pi | 扩展 `tool_call` 事件 | `bypass-yes-guard.ts` → `danger-guard-pi.py` | `~/.pi/agent/` |

---

## 安装

```bash
git clone https://github.com/zzusec/bypass-yes.git
cd bypass-yes
bash install-all.sh          # 五家一起装；只要守卫不要 yolo 用 --no-bypass
```

装完**重启客户端**（pi 在会话里 `/reload` 热加载即可）；Codex 还要执行 `/hooks`
把两条 danger-guard **Trust** 一次，否则钩子静默不执行
（只需第一次——之后重装是就地更新，不会让 Trust 失效）。

只装某一个就跑对应的脚本（各家配置落点不同）：

```bash
bash install.sh --bypass      # Claude Code
bash install-codex.sh         # Codex（≥ 0.142）
bash install-codebuddy.sh     # CodeBuddy
bash install-zcode.sh         # zcode（Z.AI CLI）
bash install-pi.sh            # pi（@earendil-works/pi-coding-agent）
```

**验证**

```bash
# Claude / CodeBuddy / zcode 共用同一入口（无输出 = 放行；deny = 拦下）
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | /usr/bin/python3 ~/.claude/hooks/danger-guard.py
echo '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}' \
  | /usr/bin/python3 ~/.claude/hooks/danger-guard.py                  # deny

# pi 桥接脚本（输出 {"level":"block|warn|safe", ...}）
/usr/bin/python3 ~/.pi/agent/hooks/danger-guard-pi.py '{"command":"rm -rf /","cwd":"/tmp"}'
```

回归测试：`bash test.sh`（Claude 系 102 条）、`bash test-codex.sh`（Codex 57 条）、
`bash test-zcode.sh`（zcode 安装 + yolo 检测 19 条）、`bash test-pi.sh`（pi 桥接 + 扩展行为 23 条）。

**可选调整**

| 想干嘛 | 怎么做 |
|---|---|
| 某类危险命令不想拦 | `echo '^\s*git\s+reset\s+--hard\b' >> ~/.claude/hooks/allowlist.txt`（五家共享） |
| 改危险命令清单 | 编辑 `~/.claude/hooks/rules.py`，重跑 install |
| 提示被 TUI 盖住 | `rules.py` 里 `NOTIFY_CENTER = True`（通知中心横幅，不抢焦点） |
| 关响铃 / 调音量 | `DANGER_GUARD_SILENT=1`；`core.py` 的 `SOUND_VOLUME` |
| pi 换 Python 解释器 | 启动前 `export DANGER_GUARD_PY=/path/to/python3` |

---

## 各家行为差异

守卫把命令分三档：**block**（不可逆毁灭，直接拒）、**warn**（危险但可能合理，想弹确认）、
**safe**（放行）。`warn` 能不能真弹确认，取决于客户端：

- **Claude Code / CodeBuddy / zcode（bypass / yolo 模式）**：客户端会吞掉 `ask`
  （实测 `git reset --hard` 直接执行），所以守卫把 `warn` 一律**升级成 block 硬拒**——
  弹不了确认的，宁可拦死也不静默放行。想放行就写进 `allowlist.txt`。
  zcode 的运行时其实认 hook 的 `ask`（yolo 下也会弹框），但为了行为可预期，统一按硬拒处理。
- **Codex（`approval_policy=never`）**：同上，`warn` 升 block；真正的确认框由
  `~/.codex/rules/danger-guard.rules` 的 `prompt` 档或沙箱提权流程弹。
- **pi**：扩展能用 `ctx.ui.confirm` 弹**真确认框**，所以 `warn` 会响铃 + 弹框问你
  （按 y 才执行）；headless（`pi -p` / `--mode json`）弹不了框时**保守硬拦**，绝不静默放行。
- **非 bypass 模式**（Claude 默认、zcode `--no-bypass` 的 build/edit）：`warn` 正常弹 `ask`。

---

## 升级

```bash
git pull && bash install-all.sh      # 或按需跑 install.sh / install-codex.sh / install-codebuddy.sh / install-zcode.sh / install-pi.sh
```

脚本幂等，会先备份；`rules.py` 和 `core.py` 每次一起复制，不会出现「脚本新、规则旧」。

---

## 卸载

```bash
rm -rf ~/.claude/hooks      # 并删掉 settings.json 里的 PreToolUse 条目
rm -rf ~/.codebuddy/hooks   # 同上
rm -rf ~/.zcode/cli/hooks   # 并把 setting.json 里 hooks.events.PreToolUse 的 danger-guard 条目删掉
rm -rf ~/.pi/agent/hooks ~/.pi/agent/extensions/bypass-yes-guard.ts   # pi 扩展 + 桥接
rm -rf ~/.codex/hooks ~/.codex/rules/danger-guard.rules   # 并删掉 hooks.json 里的条目
```

install 每次都留 `*.bak.cmdguard` 备份，拷回去即可还原（含 `defaultMode`、`permission.mode`、
`sandbox` 等设置）。

---

MIT · 感谢 [linuxdo](https://linux.do/) 社区的讨论与反馈。
