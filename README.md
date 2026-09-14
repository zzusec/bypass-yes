# 命令守卫 · Claude Code / Codex / CodeBuddy

**yolo 让你不用点 Yes；守卫让你敢开 yolo。**

三家官方的免确认开关——`claude --dangerously-skip-permissions`、
`codex --dangerously-bypass-approvals-and-sandbox`（俗称 yolo）、`codebuddy -y`——
解决的是同一件事：别再弹窗。但它们是**不看命令内容，一律放行**。

本守卫是叠在 yolo 之上的一层：yolo 照开，日常命令照样静默放行，只有危险的那几条被拦下。

| 判定 | 例子 | 行为 |
|---|---|---|
| 安全 | `ls`、`npm run build`、`rm -rf node_modules` | 静默放行 |
| 危险 | `git reset --hard`、`npm publish`、`rm -rf ~/项目` | 响铃 + 打出原因 + 拒绝 |
| 毁灭级 | `mkfs`、`rm -rf /`、`dd` 写盘 | 响铃 + 拒绝 |

---

## 为什么光开 yolo 不行

**同一句需求「清理构建产物重新构建」，AI 把路径写错了：**

```
只开 yolo：
  $ rm -rf ~/my-app      ← 本想删 dist
  （执行完毕，无提示，项目没了）

yolo + 守卫：
  $ rm -rf dist          → 放行，一声不吭
  $ rm -rf ~/my-app      → 拒绝
  [命令守卫] 已拦截:rm -rf 删除整个项目/系统路径或目标不明
```

差别不在「拦得多」，而在**只有那一条被拦**——`rm -rf dist` 照常放行，AI 的活没被打断。

| 命令 | yolo | 会怎样 | 守卫 |
|---|---|---|---|
| `rm -rf node_modules` / `dist` | 执行 | — | 放行 |
| `rm -rf ~/你的项目` | 执行 | 项目没了，连提示都没有 | 拒绝 + 响铃 |
| `git reset --hard` | 执行 | 未提交改动全丢 | 拒绝 |
| `git push --force` | 执行 | 远程历史被改，同事拉不到代码 | 拒绝 |
| `curl x.sh \| bash` | 执行 | 陌生远程代码直接跑 | 拒绝 |
| `npm publish` | 执行 | 源码公网可见、版本号被占用 | 拒绝 |
| `mkfs`、`rm -rf /` | 执行 | 盘没了 | 拒绝 |
| 出事之后 | 静默 | 你不知道发生了什么 | 响铃 + 打出原因 |

**官方的静态 deny 顶不上**：`Bash(rm -rf /*)` 的 `*` 跨 `/` 匹配，拦的不是根目录而是
**所有绝对路径**，连 `node_modules` 一起拦死。守卫按删除目标分级才能两全：

| 删除目标 | 判定 |
|---|---|
| 项目内子目录、`/tmp/…` | 放行 |
| 家目录直接子项、git 仓库根、当前目录（= 整个项目） | 拒绝 |
| `/`、`~`、`/Users/xxx`、系统路径 | 拒绝 |

> **一句话：只开 yolo = 拆了刹车；yolo + 守卫 = 刹车还在，只是不用每次都踩。**

判定细节：只匹配命令不匹配数据（`echo "rm -rf /"` 不拦）；`eval` / `bash -c` 里的内容会补扫；
客户端 wrapper（`zsh -c '… && eval "你的命令"'`）会拆开看内层。

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
