# -*- coding: utf-8 -*-
"""危险命令规则库 —— Claude Code / Codex / CodeBuddy / zcode / pi / Qoder / Gemini / Cursor / agy 九家共用的唯一真源。

改这里就等于改九家:install.sh / install-codex.sh / install-codebuddy.sh /
install-zcode.sh / install-pi.sh / install-qoder.sh / install-gemini.sh /
install-cursor.sh / install-agy.sh / gen_codex_rules.py 全部从本文件派生各自的产物
(hook 判定、Codex 的 .rules、Claude 系的静态 deny)。

判定分三档:
  BLOCK       不可逆毁灭 → 直接拒绝(deny)
  WARN        危险但可能合理 → 弹确认(ask / Codex 的 prompt)

另有一份 CODEX_RULES:Codex 的 hook 只认 deny、不支持 ask,「危险 → 弹确认」必须
靠 ~/.codex/rules/*.rules 的 prefix_rule(argv 前缀匹配)表达。正则没法自动翻译成
argv 前缀,所以这份要显式维护;gen_codex_rules.py 会校验每条的 source_reason 在本
文件里真实存在,防止改了上面的 reason 而这里没跟上。
"""

# 系统关键目录(chmod/chown 等仅当作用于这些目录时才视为危险)
SYS = r"(?:/(?:etc|usr|bin|sbin|var|lib|lib64|boot|opt|root|System|Library|Applications)\b|\s/\s|\s/$|\s/\*)"

# BLOCK:不可逆毁灭 → 拒绝
BLOCK = [
    (r"\bmkfs(\.\w+)?\b",                                     "mkfs 格式化文件系统"),
    (r"\bdd\b[^\n]*\bof=/dev/r?(disk|sd|hd|nvme)",            "dd 写入物理磁盘"),
    (r">\s*/dev/r?(disk|sd|hd|nvme)",                         "重定向覆写物理磁盘"),
    (r":\s*\(\s*\)\s*\{\s*:\s*\|\s*:&\s*\}\s*;\s*:",          "fork bomb 炸弹"),
    (r"\bdiskutil\b[^\n]*\beraseDisk\b",                      "diskutil 抹掉整盘"),
]

# WARN:危险但可能合理 → 弹确认
# 只保留「系统级 / 难以撤销 / 对外发布」的操作。日常 dev 命令(kill、killall、rmdir、
# unlink、git branch -D、sudo 本身等)一律不在此列,避免误拦。
WARN = [
    (r"\bdiskutil\b[^\n]*\b(erase|partition|reformat|eraseVolume|eraseDisk)\b", "diskutil 抹盘/分区"),
    (r"\bfdisk\b",                                                              "fdisk 分区"),
    (r"\bshutdown\b",                                                           "shutdown 关机"),
    (r"\breboot\b",                                                             "reboot 重启"),
    (r"\bhalt\b",                                                               "halt 停机"),
    (r"\bpoweroff\b",                                                           "poweroff 断电"),
    (r"\bchmod\b[^\n]*(?:-R|--recursive)[^\n]*" + SYS,                          "chmod -R 改系统目录权限"),
    (r"\bchown\b[^\n]*(?:-R|--recursive)[^\n]*" + SYS,                          "chown -R 改系统目录属主"),
    (r">\s*/etc/",                                                             "写入 /etc 系统文件"),
    (r"\bcurl\b[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b",                               "curl 管道执行远程脚本"),
    (r"\bwget\b[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b",                               "wget 管道执行远程脚本"),
    # 选项只在本命令段内找(不跨 ; && |):否则 `git push origin main && rm -f x`
    # 里 rm 的 -f 会被算成 git push -f,误判成强制推送
    (r"\bgit\s+push\b[^;&|\n]*(--force\b|--force-with-lease\b|\s-f\b)",         "git 强制推送"),
    (r"\bgit\s+reset\b[^;&|\n]*--hard\b",                                       "git reset --hard 丢弃改动"),
    (r"\bgit\s+clean\b[^;&|\n]*\s-\w*f",                                        "git clean -f 删未跟踪文件"),
    (r"\bnpm\s+publish\b",                                                      "npm publish 发布包"),
    (r"\bcrontab\b[^\n]*\s-r\b",                                                "crontab -r 清空定时任务"),
    (r"\bdocker\b[^\n]*\bprune\b[^\n]*(--volumes|--all|\s-a\b)",                "docker prune 清理(含数据卷/全部)"),
]

# 被拦时除了响铃,要不要再发一条 macOS 通知中心横幅(不带按钮、不抢焦点)。
# 终端提示可能被 TUI 重绘盖掉,开着这个能保证看得见。
NOTIFY_CENTER = False

# rm 目标分级参数:这些根目录下的路径视为临时目录,可静默删除
TEMP_ROOTS = ("/tmp", "/private/tmp")

# rm 分级的 reason 文案。这几条不在 BLOCK/WARN 表里(由 rm 目标分级动态产生),
# 但 CODEX_RULES 要引用它们,所以统一放在这里当真源,避免两边文案漂移。
RM_BLOCK_REASON = "rm 递归删除根目录/家目录/整个用户目录/一级系统目录"
RM_WARN_REASON = "rm -rf 删除整个项目/系统路径或目标不明"
RM_SAFE_REASON = "rm -rf 目标为普通目录,自动放行"

# bypass 模式下客户端会吞掉守卫的 ask(实测:git reset --hard 在 -p 下直接执行了)。
# 弹不了确认,那就只有「放行 / 拒绝」二选一。
#
# BYPASS_DENY_ALL_WARN = True  → bypass 下整个 WARN 档一律硬拒(生效中)。
#                                想放行某类命令就写进 allowlist.txt(白名单优先于 WARN),
#                                例如 `^\s*git\s+reset\s+--hard\b`。
# BYPASS_DENY_ALL_WARN = False → 只硬拒 BYPASS_DENY_REASONS 里列出的那几条,其余 WARN
#                                在 bypass 下仍是 ask(会被吞 → 实际放行)。
BYPASS_DENY_ALL_WARN = True

BYPASS_DENY_REASONS = {
    RM_WARN_REASON,
}

# Claude Code 静态 deny(permissions.deny)。
# ⚠ deny 的 * 会跨 / 匹配:"Bash(rm -rf /*)" 不是"只拦根目录",而是拦下所有绝对路径的
# rm -rf(连 /tmp/xxx、项目内 node_modules 都拦),且 deny 优先级最高、bypassPermissions
# 也压不住。所以这里只写精确的毁灭级形态,路径分级交给 danger-guard。
CLAUDE_DENY = [
    "Bash(rm -rf /)",
    "Bash(rm -fr /)",
    "Bash(rm -rf /Users)",
    "Bash(rm -rf ~)",
    "Bash(mkfs *)",
    "Bash(dd if=* of=/dev/*)",
]

# 已知会误拦大量正常命令的过宽 deny,安装时自动剔除
CLAUDE_DENY_OVERBROAD = [
    "Bash(sudo *)",
    "Bash(sudo*)",
    "Bash(*)",
    "Bash(rm -rf *)",
    "Bash(rm -r *)",
    "Bash(rm *)",
    "Bash(rm -rf /*)",
    "Bash(rm -rf ~*)",
    "Bash(rm -rf /Users/*)",
    "Bash(git reset --hard *)",
    "Bash(git clean -f *)",
    "Bash(git push --force *)",
]

# Codex 的 .rules 条目:(argv 前缀, decision, justification, source_reason)
#   decision: prompt(弹确认) / forbidden(直接拒绝)
#   source_reason: 必须能在 BLOCK 或 WARN 的 reason 里找到,gen_codex_rules.py 会校验
#
# 注意 rules 是 argv 前缀匹配,多条命中取最严格(forbidden > prompt > allow)。
# 不能写整类 ["rm"],否则普通 rm foo.txt 也会弹确认 / 在 exec 模式被拒。
CODEX_RULES = [
    (["rm", "-rf"],            "prompt",    "rm -rf 递归强制删除",            "rm -rf 删除整个项目/系统路径或目标不明"),
    (["rm", "-fr"],            "prompt",    "rm -fr 递归强制删除",            "rm -rf 删除整个项目/系统路径或目标不明"),
    (["rm", "-r", "-f"],       "prompt",    "rm -r -f 递归强制删除",          "rm -rf 删除整个项目/系统路径或目标不明"),
    (["rm", "-f", "-r"],       "prompt",    "rm -f -r 递归强制删除",          "rm -rf 删除整个项目/系统路径或目标不明"),
    (["shutdown"],             "prompt",    "shutdown 关机",                 "shutdown 关机"),
    (["reboot"],               "prompt",    "reboot 重启",                   "reboot 重启"),
    (["halt"],                 "prompt",    "halt 停机",                     "halt 停机"),
    (["poweroff"],             "prompt",    "poweroff 断电",                 "poweroff 断电"),
    (["fdisk"],                "prompt",    "fdisk 分区",                    "fdisk 分区"),
    (["diskutil", "eraseVolume"],   "prompt",    "diskutil 抹卷",           "diskutil 抹盘/分区"),
    (["diskutil", "partitionDisk"], "prompt",    "diskutil 分区",           "diskutil 抹盘/分区"),
    (["diskutil", "reformat"],      "prompt",    "diskutil 重新格式化",      "diskutil 抹盘/分区"),
    (["diskutil", "eraseDisk"],     "forbidden", "diskutil 抹掉整盘,不可逆", "diskutil 抹掉整盘"),
    (["mkfs"],                      "forbidden", "mkfs 格式化文件系统,不可逆", "mkfs 格式化文件系统"),
    (["git", "push", "--force"],    "prompt",    "git 强制推送",            "git 强制推送"),
    (["git", "push", "-f"],         "prompt",    "git 强制推送",            "git 强制推送"),
    (["git", "reset", "--hard"],    "prompt",    "git reset --hard 丢弃改动", "git reset --hard 丢弃改动"),
    (["git", "clean", "-f"],        "prompt",    "git clean -f 删未跟踪文件", "git clean -f 删未跟踪文件"),
    (["git", "clean", "-fd"],       "prompt",    "git clean -fd 删未跟踪文件/目录", "git clean -f 删未跟踪文件"),
    (["git", "clean", "-df"],       "prompt",    "git clean -df 删未跟踪文件/目录", "git clean -f 删未跟踪文件"),
    (["git", "clean", "-fdx"],      "prompt",    "git clean -fdx 删未跟踪+忽略文件", "git clean -f 删未跟踪文件"),
    (["npm", "publish"],       "prompt",    "npm publish 发布包",            "npm publish 发布包"),
    (["crontab", "-r"],        "prompt",    "crontab -r 清空定时任务",       "crontab -r 清空定时任务"),
]
