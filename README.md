# bypass-yes · 命令守卫

**Claude Code / Codex / CodeBuddy / zcode / pi / Qoder / Gemini CLI / Cursor / agy /
opencode / Factory droid / Crush / GitHub Copilot CLI 十三家通用。**

**yolo 让你不用点 Yes；守卫让你敢开 yolo。**

## 和官方 yolo 的区别

十三家官方都有「免确认」姿态——Claude `--dangerously-skip-permissions`、
Codex `--dangerously-bypass-approvals-and-sandbox`（俗称 yolo）、CodeBuddy `-y`、
zcode `--mode yolo`、Qoder `--dangerously-skip-permissions`、
Gemini CLI `--yolo`、Cursor 的自动执行模式、agy `--dangerously-skip-permissions`（turbo）、
opencode `run --auto`、droid 的 `auto-*` 档、Crush `--yolo`、Copilot CLI `--allow-all-tools`、
pi 干脆没有沙箱也不审批任何命令（等于一直 yolo）。
它们**不看命令内容，一律放行**。

守卫不是替代品，是**叠在 yolo 上面的一层**（能在配置文件里设免确认的，install 会一并开好；
Gemini CLI / opencode / Crush / Copilot CLI 的 yolo 只能命令行给，install 不碰；
agy 不用开 yolo——守卫直接回 `allow`，见下文）：

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

十三家共用同一套判定引擎（`core.py`）和规则库（`rules.py`，唯一真源），
只是各家协议不同，由不同入口脚本翻译输出：

| 客户端 | 拦截机制 | 入口 | 配置落点 |
|---|---|---|---|
| Claude Code | PreToolUse hook | `danger-guard.py` | `~/.claude/settings.json` |
| CodeBuddy | PreToolUse hook（同 Claude 协议） | `danger-guard.py` | `~/.codebuddy/settings.json` |
| zcode | PreToolUse hook（同 Claude 协议） | `danger-guard.py` | `~/.zcode/cli/setting.json` |
| Qoder CLI | PreToolUse hook（同 Claude 协议） | `danger-guard.py` | `~/.qoder/settings.json` |
| Codex CLI | hooks.json + `.rules` | `danger-guard-codex.py` | `~/.codex/` |
| Gemini CLI | BeforeTool hook | `danger-guard-gemini.py` | `~/.gemini/settings.json` |
| Cursor | `hooks.json` 的 `beforeShellExecution` | `danger-guard-cursor.py` | `~/.cursor/hooks.json` |
| pi | 扩展 `tool_call` 事件 | `bypass-yes-guard.ts` → `danger-guard-pi.py` | `~/.pi/agent/` |
| agy（Antigravity CLI） | `hooks.json` 的 `PreToolUse` | `danger-guard-agy.py` | `~/.gemini/config/hooks.json` ⚠️ |
| opencode | 插件的 `tool.execute.before` | `bypass-yes-opencode.js` → `danger-guard-pi.py` | `~/.config/opencode/plugin/` |
| Factory droid ※ | PreToolUse hook（同 Claude 协议） | `danger-guard.py` | `~/.factory/hooks.json` |
| Crush ※ | `crush.json` 的 `hooks.PreToolUse` | `danger-guard-crush.py` | `~/.config/crush/crush.json` |
| GitHub Copilot CLI ※ | `PreToolUse` hook（PascalCase，走 VS Code 兼容格式） | `danger-guard-copilot.py` | `~/.copilot/hooks/` |

⚠️ = agy 的落点只有 `~/.gemini/config/hooks.json` 这一个。另外两个位置都是坑：
`~/.gemini/hooks.json` 在 `/hooks` 里列得出来、日志也写 loaded，但**实测根本不执行**；
`~/.agents/hooks.json` 是**项目级**（cwd 下的 `.agents/`），只在 cwd 恰好是家目录时碰巧生效。

※ = **没在真实客户端里端到端验证过**（作者机器上没装这三家）：协议按各自官方文档实现、回归测试也
全绿，但「客户端到底有没有真调用钩子」没实测。真要用先拿下面的 canary 取证一次 —— agy 当初就是靠
这一步才发现配置落点写错了（配置写在 `~/.gemini/hooks.json`，`/hooks` 列得出来、日志也写 loaded，
就是不执行）。跑通了欢迎提 issue 让我把 ※ 去掉。

---

## 安装

```bash
git clone https://github.com/zzusec/bypass-yes.git
cd bypass-yes
bash install-all.sh          # 十三家一起装；只要守卫不要 yolo 用 --no-bypass
```

装完**重启客户端**（pi 在会话里 `/reload` 热加载即可）；Codex 还要执行 `/hooks`
把两条 danger-guard **Trust** 一次，否则钩子静默不执行
（只需第一次——之后重装是就地更新，不会让 Trust 失效）。
opencode 的插件在下次启动时加载。yolo 只能命令行给的几家：`gemini --yolo`、
`opencode run --auto`、`crush --yolo`、`copilot --allow-all-tools`
（`settings.json` 里都没有对应开关）。**agy 例外：别加 `--dangerously-skip-permissions`**，
守卫对安全命令直接回 `allow`，本来就不弹框，加了反而把 `deny` 一起吞掉。

只装某一个就跑对应的脚本（各家配置落点不同）：

```bash
bash install.sh --bypass      # Claude Code
bash install-codex.sh         # Codex（≥ 0.142）
bash install-codebuddy.sh     # CodeBuddy
bash install-zcode.sh         # zcode（Z.AI CLI）
bash install-pi.sh            # pi（@earendil-works/pi-coding-agent）
bash install-qoder.sh         # Qoder CLI
bash install-gemini.sh        # Gemini CLI
bash install-cursor.sh        # Cursor（Agent / cursor-agent）
bash install-agy.sh           # agy（Antigravity CLI）
bash install-opencode.sh      # opencode
bash install-droid.sh         # Factory droid（未端到端验证）
bash install-crush.sh         # Crush（未端到端验证）
bash install-copilot.sh       # GitHub Copilot CLI（未端到端验证）
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

# Gemini CLI（输出 {"decision":"deny", ...}）
echo '{"tool_name":"run_shell_command","tool_input":{"command":"rm -rf /"}}' \
  | /usr/bin/python3 ~/.gemini/hooks/danger-guard-gemini.py

# Cursor（输出 {"permission":"deny|ask", ...}）
echo '{"command":"rm -rf /","cwd":"/tmp"}' \
  | /usr/bin/python3 ~/.cursor/hooks/danger-guard-cursor.py

# agy（输出 {"decision":"allow|deny|force_ask", ...}）
echo '{"toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf /","Cwd":"/tmp"}}}' \
  | /usr/bin/python3 ~/.gemini/hooks/danger-guard-agy.py

# opencode（插件调的是通用桥接，输出 {"level":"block|warn|safe", ...}）
/usr/bin/python3 ~/.config/opencode/hooks/danger-guard-pi.py '{"command":"rm -rf /","cwd":"/tmp"}'

# Factory droid（同 Claude 协议，工具名是 Execute）
echo '{"tool_name":"Execute","tool_input":{"command":"rm -rf /"},"cwd":"/tmp"}' \
  | /usr/bin/python3 ~/.factory/hooks/danger-guard.py

# Crush（输出 {"decision":"deny", ...}，工具名是小写 bash）
echo '{"tool_name":"bash","tool_input":{"command":"rm -rf /"},"cwd":"/tmp"}' \
  | /usr/bin/python3 ~/.config/crush/hooks/danger-guard-crush.py

# GitHub Copilot CLI（输出平铺的 {"permissionDecision":"deny|ask", ...}）
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"},"cwd":"/tmp"}' \
  | /usr/bin/python3 ~/.copilot/hooks/danger-guard-copilot.py
```

回归测试（13 个脚本，共 368 条，各自独立可跑）：

```bash
for t in test.sh test-codex.sh test-codebuddy.sh test-zcode.sh test-pi.sh test-qoder.sh \
         test-gemini.sh test-cursor.sh test-agy.sh test-opencode.sh test-crush.sh \
         test-droid.sh test-copilot.sh; do printf '%-20s ' "$t"; bash "$t" | tail -1; done
```

`test.sh` 102 条（Claude 系判定引擎，规则改动主要看这个）、`test-codex.sh` 57 条、
`test-codebuddy.sh` 15 条、`test-zcode.sh` 19 条、`test-pi.sh` 23 条、`test-qoder.sh` 18 条、
`test-gemini.sh` 16 条、`test-cursor.sh` 16 条、`test-agy.sh` 22 条、
`test-opencode.sh` 19 条（需要 node）、`test-crush.sh` 19 条、`test-droid.sh` 17 条、
`test-copilot.sh` 26 条。各家的 test 都在临时目录里真跑一遍对应的 install，不会碰你的真实配置。

**不确定钩子到底有没有被触发？挂 canary**

上面那些命令验证的是「守卫脚本自己判得对不对」，验证不了「客户端有没有真的调用它」。
`danger-guard-canary.sh` 就是干这个的：记一行日志（时间 / 判定 / 命令），然后把判定原样
交给同目录的守卫入口 —— 行为和没挂时一致，只是多了证据。

```bash
cp danger-guard-canary.sh ~/.claude/hooks/     # 拷到该家的 hooks 目录
# 把配置里 PreToolUse 的 hook 命令改成 canary 的绝对路径(重跑 install-*.sh 会改回来)
cat ~/.claude/hooks/guard-canary.log           # 跑几个命令后看这里有没有记录
```

日志形如 `2026-09-19 22:23:36	deny	git reset --hard`。空文件 = 一次都没被调用，
那就是配置没接上或 matcher 没匹配上，不是守卫的问题。脚本自动适配各家（入口文件名、
判定键名、命令字段都不同），拷过去就能用。

> ⚠ canary 是 **fail-open** 的：它自己挂掉时命令会照常执行、只是没有守卫。
> 所以只作临时取证，拿到证据就拆：删掉 canary 和日志，重跑 install，hook 命令会改回直连 python。

**可选调整**

| 想干嘛 | 怎么做 |
|---|---|
| 某类危险命令不想拦 | `echo '^\s*git\s+reset\s+--hard\b' >> ~/.claude/hooks/allowlist.txt`（各家共享） |
| 改危险命令清单 | 编辑 `~/.claude/hooks/rules.py`，重跑 install |
| 提示被 TUI 盖住 | `rules.py` 里 `NOTIFY_CENTER = True`（通知中心横幅，不抢焦点） |
| 关响铃 / 调音量 | `DANGER_GUARD_SILENT=1`；`core.py` 的 `SOUND_VOLUME` |
| pi / opencode 换 Python 解释器 | 启动前 `export DANGER_GUARD_PY=/path/to/python3` |
| 免确认模式吞掉了确认框<br>（Cursor 自动执行、Copilot `--allow-all-tools`；agy 别开 turbo） | 启动前 `export DANGER_GUARD_BYPASS=1`（WARN 从弹框改硬拒） |

---

## 各家行为差异

守卫把命令分三档：**block**（不可逆毁灭，直接拒）、**warn**（危险但可能合理，想弹确认）、
**safe**（放行）。`warn` 能不能真弹确认，取决于客户端：

- **Claude Code / CodeBuddy / zcode / Qoder（bypass / yolo 模式）**：客户端会吞掉 `ask`
  （实测 `git reset --hard` 直接执行），所以守卫把 `warn` 一律**升级成 block 硬拒**——
  弹不了确认的，宁可拦死也不静默放行。想放行就写进 `allowlist.txt`。
  zcode 的运行时其实认 hook 的 `ask`（yolo 下也会弹框），但为了行为可预期，统一按硬拒处理。
- **Codex（`approval_policy=never`）**：同上，`warn` 升 block；真正的确认框由
  `~/.codex/rules/danger-guard.rules` 的 `prompt` 档或沙箱提权流程弹。
- **Gemini CLI**：hook 输出只有 `allow` / `deny` 两档、**没有 ask 这一档**，
  所以无论开不开 yolo，`warn` 都硬拒（想放行写 `allowlist.txt`）。
  另外放行走的是「不输出」而不是 `decision: allow`——显式 allow 有可能把 Gemini
  自己的确认框也一并免掉，那是放宽权限，不是守卫该干的事。
- **Cursor**：`beforeShellExecution` 认 `ask`，所以 `warn` 会弹确认框。
  但 Cursor 在自动执行 / 免确认设置下会吞掉 ask，那种场景请在启动前
  `export DANGER_GUARD_BYPASS=1`，守卫会把 `warn` 升成硬拒。
- **pi**：扩展能用 `ctx.ui.confirm` 弹**真确认框**，所以 `warn` 会响铃 + 弹框问你
  （按 y 才执行）；headless（`pi -p` / `--mode json`）弹不了框时**保守硬拦**，绝不静默放行。
- **agy**：唯一一家**由守卫本身给 yolo** 的——安全命令回 `decision: allow`，agy 直接执行、
  一次都不弹框，所以**不需要也不建议开 turbo**（`--dangerously-skip-permissions` 是全量放行，
  连 `rm -rf /` 都一起放，还会把守卫的 `deny` 一起吞掉）。
  早期版本放行走的是「不输出」，实测那等于交还 agy 自己的审批——**安全命令照样弹框**，
  2026-09-20 就是这么翻的车。注意输出一个没有 `decision` 的 JSON 反而会被当成拦截。
  `warn` 用 `force_ask` 不用 `ask`：`ask` 会命中 agy 的「Always Allow」缓存，
  用户对某条 `git reset --hard` 点过一次「总是允许」，守卫就形同虚设。
- **opencode**：插件的 `tool.execute.before` 只有「放行」和「抛错」两种结果，**没有确认框**，
  所以 `warn` 和 `block` 一样硬拒（抛出的错误会原样显示并回给模型）。这一档与 `--auto` 无关，
  开不开 auto 都拦得住。
- **Factory droid**：协议与 Claude 一致，认 `ask`。它的 payload 直接带 `permission_mode`，
  是 `auto-*`（auto-low / auto-medium / auto-high）时确认框弹不出来，守卫自动把 `warn` 升硬拒；
  `off` / `spec` 下正常弹 `ask`。不用去猜配置文件。
- **Crush**：`decision` 只有 `allow` / `deny` / `none`，**没有 ask**，所以 `warn` 一律硬拒
  （它还有 `--yolo`，更不能赌用户没开）。
- **GitHub Copilot CLI**：认 `ask`，`warn` 会弹 hook 确认框。它有个别家都没有的坑 ——
  `preToolUse` 命令钩子是 **fail-closed**：钩子崩溃或非 0 退出会**拒掉**命令而不是放行，
  所以 `danger-guard-copilot.py` 连 `import` 都包在 `try` 里、任何异常一律 `exit 0`
  （装坏了宁可当次不守卫，也不能把客户端锁死）。超时是唯一例外，官方规定一律 fail-open。
- **非 bypass 模式**（Claude 默认、zcode / Qoder `--no-bypass`）：`warn` 正常弹 `ask`。

---

## 升级

```bash
git pull && bash install-all.sh      # 或按需跑 install.sh / install-codex.sh / install-codebuddy.sh / install-zcode.sh / install-pi.sh / install-qoder.sh / install-gemini.sh / install-cursor.sh / install-agy.sh / install-opencode.sh / install-droid.sh / install-crush.sh / install-copilot.sh
```

脚本幂等，会先备份；`rules.py` 和 `core.py` 每次一起复制，不会出现「脚本新、规则旧」。

---

## 卸载

```bash
rm -rf ~/.claude/hooks      # 并删掉 settings.json 里的 PreToolUse 条目
rm -rf ~/.codebuddy/hooks   # 同上
rm -rf ~/.zcode/cli/hooks   # 并把 setting.json 里 hooks.events.PreToolUse 的 danger-guard 条目删掉
rm -rf ~/.qoder/hooks       # 并删掉 settings.json 里 hooks.PreToolUse 的条目
rm -rf ~/.gemini/hooks      # Gemini CLI + agy 共用这个目录:并删掉 settings.json 里 hooks.BeforeTool
                            # 以及 config/hooks.json 里的 bypass-yes 键
rm -rf ~/.cursor/hooks      # 并删掉 hooks.json 里 beforeShellExecution 的条目
rm -rf ~/.pi/agent/hooks ~/.pi/agent/extensions/bypass-yes-guard.ts   # pi 扩展 + 桥接
rm -rf ~/.codex/hooks ~/.codex/rules/danger-guard.rules   # 并删掉 hooks.json 里的条目
rm -rf ~/.config/opencode/hooks ~/.config/opencode/plugin/bypass-yes-opencode.js   # opencode 插件 + 桥接
rm -rf ~/.factory/hooks     # 并删掉 hooks.json 里 PreToolUse 的 danger-guard 条目
rm -rf ~/.config/crush/hooks   # 并删掉 crush.json 里 hooks.PreToolUse 的 bypass-yes 条目
rm -rf ~/.copilot/hooks  # Copilot CLI:守卫把 bypass-yes.json + danger-guard-copilot.py + core.py
                         # + rules.py + chime.wav 都放在这里;目录里若还有你自己的 *.json 就别整目录删
```

install 每次都留 `*.bak.cmdguard` 备份，拷回去即可还原（含 `defaultMode`、`permission.mode`、
`sandbox` 等设置）。

---

## 暂时接不了的

- **aider**：没有钩子系统。上游 [issue #5712](https://github.com/Aider-AI/aider/issues/5712)
  还在讨论加 hook，目前没有任何「命令执行前」的拦截点，只能靠包一层 shell —— 那已经不是本项目的活了。
- **Amp**：官方手册里没有 PreToolUse 一类的钩子，只有 `settings.json` / MCP / `AGENT.md`。
  等它出了钩子再说。

> Copilot CLI 免费档就能用（装守卫本身不花钱），但 CLI 的请求是计量的
> —— 2026-06-01 起统一算 AI Credits，免费档额度用完要等下个周期，只有付费档能加购。

---

## 基础设施伙伴

测试矩阵、安装镜像与文档站由 [BlueServers](https://blueservers.com/) 通过其社会支持计划提供服务器支持。

---

MIT · 感谢 [linuxdo](https://linux.do/) 社区的讨论与反馈。
