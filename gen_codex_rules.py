#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 rules.py 生成 Codex 的 ~/.codex/rules/danger-guard.rules。

Codex 的 hook 不支持 ask,「危险 → 弹确认」只能写进 .rules(argv 前缀匹配)。而 .rules
没法从正则自动推导出来,所以 CODEX_RULES 这份要显式维护 —— 为了防止它和规则库漂移,
每条都带一个 source_reason,生成时会校验它确实存在于 rules.BLOCK / rules.WARN:
改了规则库的 reason 却忘了同步这里,生成直接失败。

用法:
  python3 gen_codex_rules.py                      # 写到仓库根目录 danger-guard.rules
  python3 gen_codex_rules.py ~/.codex/rules/danger-guard.rules
  python3 gen_codex_rules.py --check              # 只校验一致性,不写文件
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rules  # noqa: E402

HEADER = '''# 本文件由 gen_codex_rules.py 从 rules.py 生成,请勿手改
# ============================================================
# 分工:毁灭级由 danger-guard-codex.py hook 直接 deny;安全命令由 hook 直接放行;
# 本文件只补「危险 → 弹确认(prompt)」这一档(Codex hook 不支持 ask,只能靠 rules)。
#
# 注意:rules 是 argv 前缀匹配,多条命中取最严格(forbidden > prompt > allow)。
# 若其他 .rules 文件对同类命令写了 forbidden,会压过这里的 prompt。

# rm:注意 rules 优先级高于 hook 的放行(实测),所以不能写整类 ["rm"],
# 否则普通 rm foo.txt 也会弹确认/在 exec 模式被拒。
# 只对常见 rm -rf 形态弹确认;普通 rm 由 hook 放行;rm -rf /、~ 由 hook 直接 deny;
# 其余变体(如 rm dir -rf)落到沙箱:工作区内直接执行,工作区外提权弹确认。
'''


def build():
    known = ({r for _, r in rules.BLOCK} | {r for _, r in rules.WARN}
             | {rules.RM_BLOCK_REASON, rules.RM_WARN_REASON, rules.RM_SAFE_REASON})
    stale = [(a, s) for a, _d, _j, s in rules.CODEX_RULES if s not in known]
    if stale:
        print("[gen_codex_rules] 以下条目的 source_reason 在 rules.py 里已不存在,"
              "说明规则库改过但 CODEX_RULES 没跟上:", file=sys.stderr)
        for argv, src in stale:
            print("  %-32s <- %s" % (" ".join(argv), src), file=sys.stderr)
        sys.exit(1)

    lines = [HEADER]
    for argv, decision, justification, _src in rules.CODEX_RULES:
        pattern = ", ".join('"%s"' % a for a in argv)
        lines.append('prefix_rule(pattern=[%s], decision="%s", justification="%s")'
                     % (pattern, decision, justification))
    return "\n".join(lines) + "\n"


def main():
    args = [a for a in sys.argv[1:]]
    if "--check" in args:
        build()
        print("[gen_codex_rules] 一致性校验通过")
        return
    dest = args[0] if args else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "danger-guard.rules")
    content = build()
    d = os.path.dirname(dest)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(dest, "w", encoding="utf-8") as f:
        f.write(content)
    print("[gen_codex_rules] 已生成", dest)


if __name__ == "__main__":
    main()
