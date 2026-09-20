#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""危险命令判定引擎 —— Claude Code / Codex / CodeBuddy / zcode / pi / Qoder / Gemini / Cursor / agy 九家共用。

规则表在 rules.py(唯一真源)。本文件只做「命令文本 → 危险等级」,不关心任何一家的
输出协议 —— 输出由各客户端的入口脚本负责:
    danger-guard.py        Claude Code / CodeBuddy / zcode / Qoder(同一套 PreToolUse 协议)
    danger-guard-codex.py  Codex CLI(hooks.json + .rules)
    danger-guard-pi.py     pi(被 command-guard.ts 扩展调用,输出 {level,reason})
    danger-guard-gemini.py Gemini CLI(BeforeTool,decision deny/allow)
    danger-guard-cursor.py Cursor(hooks.json 的 beforeShellExecution,permission deny/ask)

    classify(cmd, cwd) -> (level, reason)

level 取值:
    block       不可逆毁灭
    warn        危险但可能合理
    allowlist   命中用户白名单
    safe        正常放行
"""

import json
import os
import re
import shlex
import subprocess

import rules

# 各家对 shell 工具的命名:Claude/CodeBuddy/zcode/Qoder 用 Bash,Codex 用 shell / local_shell,
# Gemini CLI 用 run_shell_command。
# pi 的小写 bash 由 command-guard.ts 扩展自行过滤、Cursor 的 beforeShellExecution
# 事件不带工具名(直接给 command),两者都不走这里。
TOOL_NAMES = ("Bash", "shell", "local_shell", "run_shell_command")

SOUND_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chime.wav")
SOUND_VOLUME = "0.5"  # afplay 相对系统音量的比例(0~1)


# ============================================================
# 预处理:屏蔽「数据」,补扫「会被执行的代码」
# ============================================================

def mask_strings(cmd):
    """把引号内字符串内容替换为空格,使命令中的「数据词」(SQL、commit 信息、echo 文本、
    参数值等)不再误触危险规则;保留引号本身及引号外的 shell 结构(管道、重定向)。"""
    out = []
    quote = None
    i, n = 0, len(cmd)
    while i < n:
        c = cmd[i]
        if quote:
            # 双引号内的反斜杠转义:跳过下一个字符
            if quote == '"' and c == '\\' and i + 1 < n:
                out.append('  ')
                i += 2
                continue
            if c == quote:
                out.append(c)
                quote = None
            else:
                out.append('\n' if c == '\n' else ' ')
            i += 1
        else:
            if c in ('"', "'"):
                quote = c
            out.append(c)
            i += 1
    return ''.join(out)


def extract_code(cmd):
    """提取会被 shell 重新执行的内联代码(bash -c / sh -c / eval),作为危险扫描的补充输入,
    防止把真正危险命令藏在引号里绕过 mask_strings()。"""
    payloads = []
    for m in re.finditer(r"\b(?:ba|z|da|t?c|k|a)?sh\b[^\n;|&]*?\s-c\s+('[^']*'|\"[^\"]*\"|\S+)", cmd):
        payloads.append(m.group(1).strip("'\""))
    for m in re.finditer(r"\beval\s+('[^']*'|\"[^\"]*\"|[^\n;|&]+)", cmd):
        payloads.append(m.group(1).strip("'\""))
    return payloads


def strip_heredocs(cmd):
    """把「定界符带引号」的 heredoc 正文清空(<<'EOF' / <<"EOF")。

    这类正文不做变量/命令替换,也不会被当作命令执行,是纯数据 —— 里面的 JS 模板串反引号、
    SQL、$(...)、reboot 之类的词都不该影响判定(否则写个 seed 脚本都要弹确认)。
    不带引号的 <<EOF 正文会被 shell 展开(可能触发命令替换),保持原样继续扫描。
    """
    if "<<" not in cmd:
        return cmd
    lines = cmd.split("\n")
    mlines = mask_strings(cmd).split("\n")   # 与原文等长,用来判断 << 是否在引号外
    if len(mlines) != len(lines):
        return cmd
    out = []
    i = 0
    while i < len(lines):
        out.append(lines[i])
        delims = []
        bare = False
        for m in re.finditer(r"<<-?", mlines[i]):
            dm = re.match(r"\s*(?:'([^']*)'|\"([^\"]*)\")", lines[i][m.end():])
            if dm:
                delims.append(dm.group(1) if dm.group(1) is not None else dm.group(2))
            else:
                bare = True   # <<EOF / <<< / << 变量:交给原逻辑保守处理
        i += 1
        if bare or not delims:
            continue
        for delim in delims:      # 多个 heredoc 时正文按顺序排列
            while i < len(lines) and lines[i].strip() != delim:
                out.append("")    # 正文清空,保留行数
                i += 1
            if i < len(lines):
                out.append("")    # 结束定界符行
                i += 1
    return "\n".join(out)


def build_scan_text(cmd):
    """用于危险匹配的文本 = 屏蔽数据后的命令 + 内联代码补扫。"""
    masked = mask_strings(cmd)
    payloads = extract_code(cmd)
    if payloads:
        return masked + "\n" + "\n".join(payloads)
    return masked


# ============================================================
# 白名单 / 提示音
# ============================================================

def allowlist_paths():
    """白名单文件:脚本同目录的 allowlist.txt,以及 Claude 侧那份(九家共享放行规则)。"""
    here = os.path.dirname(os.path.abspath(__file__))
    return [
        os.path.join(here, "allowlist.txt"),
        os.path.expanduser("~/.claude/hooks/allowlist.txt"),
    ]


def load_user_allow():
    """读白名单(每行一个正则;# 注释;坏正则跳过;文件缺失忽略)。"""
    out = []
    for path in allowlist_paths():
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    s = line.strip()
                    if not s or s.startswith("#"):
                        continue
                    try:
                        re.compile(s)
                        out.append(s)
                    except re.error:
                        continue
        except Exception:
            pass
    return out


def play_sound():
    """后台异步播放提示音,不阻塞决策返回。"""
    if os.environ.get("DANGER_GUARD_SILENT"):   # 回归测试批量跑用例时静音
        return
    try:
        subprocess.Popen(
            ["afplay", "-v", SOUND_VOLUME, SOUND_FILE],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def _osa_quote(s):
    """转成 AppleScript 字符串字面量(只有通知中心那条路用得到)。"""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify_user(cmd, reason):
    """把「为什么被拦」写到命令行,不等待输入、不弹系统对话框。

    提示直接写 /dev/tty,也就是你跑 Claude / CodeBuddy 的那个终端;
    写不到就拉倒(TUI 可能重绘盖掉,CI 里压根没有 tty)。
    rules.NOTIFY_CENTER = True 时额外发一条 macOS 通知中心横幅(不带按钮、不抢焦点)。

    返回是否成功写到终端。声音由调用方在前面响(core.play_sound)。
    """
    if os.environ.get("DANGER_GUARD_ASK") == "0":
        return False
    shown = " ".join(cmd.split())[:400]
    text = ("[命令守卫] 已拦截:%s\n  %s\n  要执行就自己跑,或把命令写进 allowlist.txt"
            % (reason, shown))
    written = False
    try:
        fd = os.open("/dev/tty", os.O_WRONLY)
        try:
            os.write(fd, ("\n" + text + "\n").encode("utf-8"))
            written = True
        finally:
            os.close(fd)
    except Exception:
        pass
    if getattr(rules, "NOTIFY_CENTER", False):
        try:
            subprocess.run(
                ["osascript", "-e",
                 'display notification %s with title "命令守卫" subtitle "已拦截"'
                 % _osa_quote(text)],
                capture_output=True, timeout=5)
        except Exception:
            pass
    return written


# ============================================================
# rm 目标分级
# ============================================================

TEMP_ROOTS = rules.TEMP_ROOTS
CMDSUB_TOKEN = "$__CMDSUB__"


def _skip_cmdsub(cmd, i):
    """从 `$(` 之后开始扫描,返回配对 `)` 之后的下标;不闭合返回 None。"""
    depth = 1
    n = len(cmd)
    while i < n:
        c = cmd[i]
        if c == "'":
            j = cmd.find("'", i + 1)
            if j < 0:
                return None
            i = j + 1
        elif c == '"':
            i += 1
            while i < n and cmd[i] != '"':
                i += 2 if cmd[i] == "\\" else 1
            if i >= n:
                return None
            i += 1
        elif c == "\\":
            i += 2
        elif cmd.startswith("$(", i):
            depth += 1
            i += 2
        elif c == "(":
            depth += 1
            i += 1
        elif c == ")":
            depth -= 1
            i += 1
            if depth == 0:
                return i
        else:
            i += 1
    return None


def mask_cmd_subs(cmd):
    """把 $(...) / `...` 整段换成占位符 $__CMDSUB__;引号或命令替换不闭合返回 None。

    以前只要命令里出现过 $( 就整条放弃 rm 分级 → 一律 ask,像
    `B=$(osascript ...); rm -rf ~/Downloads/x.app` 这种命令替换跟 rm 目标毫无关系的
    也被误拦。换成占位符后:沾到它的赋值/rm 目标展开不出值,照旧按「目标不明」判 warn,
    其余目标仍按真实路径分级。
    """
    out = []
    i, n = 0, len(cmd)
    in_dq = False
    while i < n:
        c = cmd[i]
        if c == "\\" and i + 1 < n:
            out.append(cmd[i:i + 2])
            i += 2
        elif not in_dq and c == "'":
            j = cmd.find("'", i + 1)
            if j < 0:
                return None
            out.append(cmd[i:j + 1])
            i = j + 1
        elif c == '"':
            in_dq = not in_dq
            out.append(c)
            i += 1
        elif c == "`":
            j = i + 1
            while j < n and cmd[j] != "`":
                j += 2 if cmd[j] == "\\" else 1
            if j >= n:
                return None
            out.append(CMDSUB_TOKEN)
            i = j + 1
        elif cmd.startswith("$(", i):
            j = _skip_cmdsub(cmd, i + 2)
            if j is None:
                return None
            out.append(CMDSUB_TOKEN)
            i = j
        else:
            out.append(c)
            i += 1
    if in_dq:
        return None
    return "".join(out)


def shell_segments(cmd):
    """按顶层 shell 分隔符切段;引号内的分隔符保留为参数内容。"""
    out, buf = [], []
    quote = None
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if quote:
            buf.append(c)
            if quote == '"' and c == "\\" and i + 1 < len(cmd):
                buf.append(cmd[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c
            buf.append(c)
        elif c in ";|&\n":
            if "".join(buf).strip():
                out.append("".join(buf))
            buf = []
        else:
            buf.append(c)
        i += 1
    if quote:
        return []
    if "".join(buf).strip():
        out.append("".join(buf))
    return out


def rm_target_level(path, cwd, home):
    """单个 rm -rf 目标的级别:
    block = 根/家目录/整个用户目录/一级系统目录;
    warn  = 整个项目级(git 仓库根、家目录直接子项、当前所在目录)、系统路径、看不清的目标;
    safe  = 普通目录/文件(项目内子目录、临时目录等)。"""
    if re.search(r"[$`]", path):
        return "warn"           # 变量/命令替换,目标真的看不清
    glob = re.search(r"[*?\[]", path)
    if glob:
        # 通配符不展开,只按它前面的固定父目录判级。
        # 判成 block 时降级为 warn —— 通配符没真指到那一级(rm -rf /* 交人确认而非硬拒)。
        head = path[:glob.start()]
        prefix, stub = head.rsplit("/", 1) if "/" in head else ("", head)
        if prefix in TEMP_ROOTS and stub:
            return "safe"      # /tmp/foo-* 具名前缀;/tmp/* 清空整个临时目录仍要确认
        level = rm_target_level(prefix or "/", cwd, home)
        return "warn" if level == "block" else level
    if path == "~":
        p = home
    elif path.startswith("~/"):
        p = os.path.join(home, path[2:])
    elif path.startswith("/"):
        p = path
    elif cwd:
        p = os.path.join(cwd, path)
    else:
        return "warn"
    p = os.path.normpath(p)

    if p == "/" or p == home:
        return "block"
    parts = p.strip("/").split("/")
    if len(parts) == 1:
        return "block"  # /etc、/usr、/tmp 等一级目录整删
    if parts[0] == "Users" and len(parts) == 2:
        return "block"  # 整个用户目录

    if cwd:
        ncwd = os.path.normpath(cwd)
        if p == ncwd or ncwd.startswith(p + "/"):
            return "warn"  # 删当前所在目录(所在项目)或其祖先
    inside_home = p.startswith(home + "/")
    if inside_home and "/" not in p[len(home) + 1:]:
        return "warn"  # 家目录直接子项,多半是整个项目/重要目录

    # 临时目录要在 .git 之前判掉:/tmp 下的一律算临时,包括临时 git clone。
    # 否则下面的 .git 检查会把 /tmp/某个仓库 当成「整个项目」拦下来 ——
    # 删不掉自己刚 clone 的目录,很常见也很烦。
    if any(p.startswith(root + "/") for root in TEMP_ROOTS):
        return "safe"

    try:
        if os.path.isdir(os.path.join(p, ".git")):
            return "warn"  # git 仓库根 = 整个项目
    except Exception:
        return "warn"

    if inside_home:
        return "safe"
    return "warn"  # 系统路径、其他用户、外接卷等,交人确认


ASSIGN_RE = re.compile(r"^([A-Za-z_]\w*)=(.*)$", re.S)


def expand_vars(text, env):
    """用同条命令里收集到的字面量赋值展开 $VAR / ${VAR};有未知变量返回 None(交人确认)。"""
    if "$" not in text:
        return text
    unknown = []

    def repl(m):
        name = m.group(1) or m.group(2)
        if name in env:
            return env[name]
        unknown.append(name)
        return ""

    out = re.sub(r"\$\{(\w+)\}|\$(\w+)", repl, text)
    return None if unknown else out


def classify_rm_targets(cmd, cwd):
    """解析原始命令里所有直接执行的 rm -rf 目标,聚合为 block/warn/safe;解析不了一律 warn。

    同一条命令里 `DIR=/tmp/x; rm -rf $DIR` 这种字面量赋值会先展开再判定 —— 展开后按真实路径
    走同一套分级(展开成家目录照样 block),既不误拦临时目录,也不会被变量绕过。
    """
    cmd = mask_cmd_subs(cmd)
    if cmd is None:
        return "warn"   # 引号/命令替换不闭合,解析不了

    home = os.path.expanduser("~")
    found = False
    worst = "safe"
    env = {}
    for segment in shell_segments(cmd):
        try:
            args = shlex.split(segment, posix=True)
        except ValueError:
            return "warn"
        if not args:
            continue

        # 前置赋值(含 `export A=b` / `A=b cmd` 形态)记进 env,供后面的 $VAR 展开
        i = 0
        if args[0] == "export" and len(args) > 1:
            i = 1
        while i < len(args):
            m = ASSIGN_RE.match(args[i])
            if not m:
                break
            value = expand_vars(m.group(2), env)
            if value is None:
                env.pop(m.group(1), None)   # 值里有未知变量 → 该变量此后不可信
            else:
                env[m.group(1)] = value
            i += 1
        args = args[i:]
        if not args or args[0] != "rm":
            continue

        has_r = has_f = False
        operands = []
        end_options = False
        for arg in args[1:]:
            if not end_options and arg == "--":
                end_options = True
            elif not end_options and arg.startswith("-") and arg != "-":
                has_r = has_r or arg == "--recursive" or "r" in arg[1:].lower()
                has_f = has_f or arg == "--force" or "f" in arg[1:].lower()
            else:
                operands.append(arg)

        if has_r and has_f:
            found = True
            if not operands:
                return "warn"
            for path in operands:
                path = expand_vars(path, env) or path
                level = rm_target_level(path, cwd, home)
                if level == "block":
                    return "block"
                if level == "warn":
                    worst = "warn"

    if not found:
        return "warn"
    return worst


def rm_arg_windows(text):
    """每个 rm 调用的参数窗口 = `rm` 之后到下一个 shell 分隔符之前的文本。

    -r/-f 必须在 rm 自己的参数里判定:整条命令通扫会把别的命令的选项算到 rm 头上,
    例如 `sips -r 90 a.jpg && rm -f b.png` 曾被误判成 rm -rf 而弹确认。
    """
    out = []
    for m in re.finditer(r"\brm\b", text):
        rest = text[m.end():]
        cut = re.search(r"[;&|\n()]", rest)
        out.append(rest[:cut.start()] if cut else rest)
    return out


def classify_rm(text, raw_cmd, cwd):
    """删根/家/用户目录级 → block;删整个项目/系统路径 → warn;普通目录 → safe。
    非递归 rm(如 `rm -f 单个文件`)不归本函数管,返回 None。"""
    rf_windows = [
        w for w in rm_arg_windows(text)
        if (re.search(r"(?:^|\s)-\w*r", w, re.I) or "--recursive" in w)
        and (re.search(r"(?:^|\s)-\w*f", w, re.I) or "--force" in w)
    ]
    if not rf_windows:
        return None
    for w in rf_windows:
        if re.search(r"(?:^|\s)(/|/\*|~|~/|~/\*|\$HOME|\$HOME/|\$HOME/\*|\$\{HOME\})(?:\s|$)", w):
            return "block"
    return classify_rm_targets(raw_cmd, cwd)


# ============================================================
# 对外唯一入口
# ============================================================

def client_dir():
    """客户端配置目录:脚本装在 <客户端目录>/hooks/ 下,配置就在上一级。"""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def is_bypass_mode():
    """客户端是否处在「不弹确认」的模式 —— 几种写法,同一个后果:

      Claude Code / CodeBuddy → settings.json 的 permissions.defaultMode == bypassPermissions
      Qoder                   → settings.json 的 general.defaultPermissionMode
                                == bypass_permissions / yolo / dont_ask
      zcode                   → setting.json(单数)的 permission.mode == "yolo"
      Codex CLI               → config.toml 的 approval_policy == "never"

    这种模式下客户端会吞掉守卫的 ask(实测 git reset --hard 直接执行),
    所以 WARN 档没法确认,只能放行或拒绝。

    zcode 略有不同:它的运行时代码显示 hook 的 deny 永远生效、ask 在 yolo 下也会升级成
    真确认框。但本项目按既定策略把 zcode 一律当 bypass 处理 —— WARN 直接硬拒,行为可预期
    (想放行某类命令就写进 allowlist.txt)。pi 不走这里:它没有「免确认模式」的概念,
    桥接脚本以 bypass=False 调用 classify,把 warn 交给扩展的 ctx.ui.confirm 弹真确认框。

    测试可用 DANGER_GUARD_BYPASS=1/0 覆盖。
    """
    env = os.environ.get("DANGER_GUARD_BYPASS")
    if env is not None:
        return env not in ("0", "", "false")
    here = client_dir()

    # Claude Code / CodeBuddy / Qoder:同一份 settings.json(复数),键名不同
    try:
        with open(os.path.join(here, "settings.json"), encoding="utf-8") as f:
            data = json.load(f)
        # Claude Code / CodeBuddy
        if data.get("permissions", {}).get("defaultMode") == "bypassPermissions":
            return True
        # Qoder:dont_ask 也是「不弹确认」,同样吞 ask
        if data.get("general", {}).get("defaultPermissionMode") in (
                "bypass_permissions", "yolo", "dont_ask"):
            return True
    except Exception:
        pass

    # zcode:setting.json(单数)permission.mode == yolo
    try:
        with open(os.path.join(here, "setting.json"), encoding="utf-8") as f:
            return json.load(f).get("permission", {}).get("mode") == "yolo"
    except Exception:
        pass

    # Codex:没有 tomllib(本机 python 3.9),够用的正则够了
    try:
        with open(os.path.join(here, "config.toml"), encoding="utf-8") as f:
            return re.search(r'^\s*approval_policy\s*=\s*"?never"?\s*$',
                             f.read(), re.M) is not None
    except Exception:
        return False


def _unwrap_rm(cmd, cwd, fallback):
    """客户端把命令包成 wrapper 时,别让它的语法噪音连累 rm 分级。

    Claude Code / CodeBuddy 的 Bash 工具实际执行的是:
        /bin/zsh -c '. <shell-snapshot> && eval "rm -rf node_modules"'
    守卫按 && 切段后,前半段引号不闭合 → shlex 解析失败 → 保守判 warn,
    结果连删除 node_modules 都被拦。

    所以掏出 eval / sh -c 的内层命令再判一次:内层 block 就 block,
    内层全 safe 才降级为 safe,否则维持原来的保守判断。
    """
    level = fallback
    for inner in extract_code(cmd):
        lvl = classify_rm(build_scan_text(inner), inner, cwd)
        if lvl == "block":
            return "block"
        if lvl == "safe":
            level = "safe"
    return level


def classify(cmd, cwd=None, bypass=None):
    """命令文本 → (level, reason)。各家入口脚本按自己的协议把 level 翻译成输出。

    bypass=None 时自动检测客户端模式,传 True/False 可强制(测试用)。
    bypass 模式下 ask 会被客户端吞掉,所以 rules.BYPASS_DENY_REASONS 里的 reason
    直接升级为 block —— 弹不了确认的那些,宁可硬拒也不静默放行。
    """
    level, reason = _classify(cmd, cwd)
    if level != "warn":
        return level, reason
    if bypass is None:
        bypass = is_bypass_mode()
    if not bypass:
        return level, reason
    if rules.BYPASS_DENY_ALL_WARN or reason in rules.BYPASS_DENY_REASONS:
        return "block", reason
    return level, reason


def _classify(cmd, cwd=None):
    core = strip_heredocs(cmd)
    scan = build_scan_text(core)
    cwd = cwd or os.getcwd()

    rm = classify_rm(scan, core, cwd)
    if rm == "warn":
        rm = _unwrap_rm(cmd, cwd, rm)

    if rm == "block":
        return "block", rules.RM_BLOCK_REASON

    for pattern, reason in rules.BLOCK:
        if re.search(pattern, scan):
            return "block", reason

    # 白名单优先于 WARN,但 BLOCK 已先拦。按命令原文匹配。
    for pattern in load_user_allow():
        if re.search(pattern, cmd):
            return "allowlist", "命中白名单,放行"

    if rm == "warn":
        return "warn", rules.RM_WARN_REASON

    for pattern, reason in rules.WARN:
        if re.search(pattern, scan):
            return "warn", reason

    return "safe", rules.RM_SAFE_REASON if rm == "safe" else "未命中危险规则,自动放行"


def get_command(data):
    """取出 hook 输入里的命令文本;Codex 偶尔给 list 形态的 argv。"""
    cmd = (data.get("tool_input") or {}).get("command", "")
    if isinstance(cmd, list):
        cmd = " ".join(str(x) for x in cmd)
    return cmd if isinstance(cmd, str) else ""
