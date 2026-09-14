# 命令守卫 · Claude Code / Codex / CodeBuddy

**yolo 让你不用点 Yes；守卫让你敢开 yolo。**

## 和官方 yolo 的区别

三家官方都有免确认开关：`claude --dangerously-skip-permissions`、
`codex --dangerously-bypass-approvals-and-sandbox`（俗称 yolo）、`codebuddy -y`。
它们**不看命令内容，一律放行**。守卫只拦其中致命的那几条：

| 命令 | 官方 yolo | 装上守卫 |
|---|---|---|
| `ls`、`npm run build`、`rm -rf node_modules` | 执行 | 执行（不打扰） |
| `rm -rf ~/你的项目` | 执行 — 项目没了，没提示 | **拦下** + 响铃 |
| `git reset --hard` | 执行 — 未提交改动全丢 | **拦下** |
| `git push --force` | 执行 — 远程历史被改 | **拦下** |
| `curl x.sh \| bash` | 执行 — 陌生代码直接跑 | **拦下** |
| `npm publish` | 执行 — 源码公网可见 | **拦下** |
| `mkfs`、`rm -rf /` | 执行 — 盘没了 | **拦下** |
| 出事之后 | 静默，你不知道发生了什么 | 终端打出是哪条、为什么 |

**不是二选一**：守卫是叠在 yolo 上的一层，`install-all.sh` 会帮你把 yolo 一起开好。

**官方的 `permissions.deny` 做不到这种粒度**——`Bash(rm -rf /*)` 的 `*` 跨 `/` 匹配，
会把 `node_modules` 一起拦死。守卫按删除目标分级：项目内子目录和 `/tmp/…` 放行，
整个项目、家目录、根和整盘拦下。

判定上还做了三件事：只匹配命令不匹配数据（`echo "rm -rf /"` 不拦）；
`eval` / `bash -c` 里的内容会补扫；客户端 wrapper（`zsh -c '… && eval "你的命令"'`）拆开看内层。

---

## 安装

```bash
git clone https://github.com/zzusec/claude-codex-bypass-yes.git
cd claude-codex-bypass-yes
bash install-all.sh          # 三家一起装；只要守卫不要 yolo 用 --no-bypass
```

装完**重启客户端**；Codex 还要执行 `/hooks` 把两条 danger-guard **Trust** 一次，否则钩子静默不执行。

只装某一个就跑对应的脚本（三家配置落点不同：Claude/CodeBuddy 是 JSON settings，
Codex 是 `hooks.json` + TOML + `.rules`）：

```bash
bash install.sh --bypass      # Claude Code
bash install-codex.sh         # Codex（≥ 0.142）
bash install-codebuddy.sh     # CodeBuddy
```

**验证**

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | /usr/bin/python3 ~/.claude/hooks/danger-guard.py                  # 无输出 = 放行
echo '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}' \
  | /usr/bin/python3 ~/.claude/hooks/danger-guard.py                  # deny
```

回归测试：`bash test.sh`（100 条）、`bash test-codex.sh`（57 条）。

**可选调整**

| 想干嘛 | 怎么做 |
|---|---|
| 某类危险命令不想拦 | `echo '^\s*git\s+reset\s+--hard\b' >> ~/.claude/hooks/allowlist.txt`（三家共享） |
| 改危险命令清单 | 编辑 `~/.claude/hooks/rules.py`，重跑 install |
| 提示被 TUI 盖住 | `rules.py` 里 `NOTIFY_CENTER = True`（通知中心横幅，不抢焦点） |
| 关响铃 / 调音量 | `DANGER_GUARD_SILENT=1`；`core.py` 的 `SOUND_VOLUME` |

---

## 升级

```bash
git pull && bash install-all.sh      # 或按需跑 install.sh / install-codex.sh / install-codebuddy.sh
```

脚本幂等，会先备份；`rules.py` 和 `core.py` 每次一起复制，不会出现「脚本新、规则旧」。

---

## 卸载

```bash
rm -rf ~/.claude/hooks      # 并删掉 settings.json 里的 PreToolUse 条目
rm -rf ~/.codebuddy/hooks   # 同上
rm -rf ~/.codex/hooks ~/.codex/rules/danger-guard.rules   # 并删掉 hooks.json 里的条目
```

install 每次都留 `*.bak.cmdguard` 备份，拷回去即可还原（含 `defaultMode`、`sandbox` 等设置）。

---

MIT · 感谢 [linuxdo](https://linux.do/) 社区的讨论与反馈。
