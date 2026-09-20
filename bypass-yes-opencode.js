/**
 * bypass-yes 命令守卫 · opencode 插件
 *
 * opencode 没有命令行 hook,拦截点是插件的 tool.execute.before。本插件在 bash 工具
 * 执行前调用隔壁 ../hooks/danger-guard-pi.py(那是个通用桥接:给它
 * {command, cwd},还你 {level, reason};判定引擎 core.py + 规则库 rules.py 与其它各家
 * 同一份真源。名字带 -pi 是历史原因,pi 和 opencode 共用它),拿回分级再决定:
 *
 *   block / warn → throw,opencode 把错误当工具失败回给模型并显示在终端(命令不执行)
 *   safe / allowlist → 放行(什么都不做)
 *
 * warn 为什么也硬拦:插件这层拿不到「弹确认框」的口子 —— tool.execute.before 只有
 * 放行和抛错两种结果。要放行某类命令就写进 allowlist.txt,别指望确认框。
 *
 * 实测过的三件事(改之前先重跑 test-opencode.sh):
 *   1. shell 工具名就是 "bash";命令在 output.args.command(input 里没有)
 *   2. throw 出去的 Error message 会原样显示,并让这一条工具调用失败
 *   3. 插件目录 ~/.config/opencode/plugin 和 plugins 都会被加载,本项目用单数那个
 *
 * 安装:install-opencode.sh 复制到 ~/.config/opencode/plugin/(全局自动发现)。
 * opencode 的免确认是 `opencode run --auto` / TUI 里的 auto 模式,守卫独立于它生效。
 */

import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const BypassYesGuard = async ({ directory, worktree }) => {
	// 本文件装在 <opencode 配置目录>/plugin/ 下,桥接脚本就在隔壁 hooks/
	const HERE = path.dirname(fileURLToPath(import.meta.url));
	const GUARD = path.join(HERE, "..", "hooks", "danger-guard-pi.py");
	// 允许用 DANGER_GUARD_PY 指定解释器;默认 /usr/bin/python3(与本项目其它入口一致)
	const PY = process.env.DANGER_GUARD_PY || "/usr/bin/python3";

	return {
		"tool.execute.before": async (input, output) => {
			if (input.tool !== "bash") return;
			const command = output?.args?.command;
			if (typeof command !== "string" || !command.trim()) return;

			const cwd = directory || worktree || process.cwd();

			let res;
			try {
				res = spawnSync(PY, [GUARD, JSON.stringify({ command, cwd })], {
					encoding: "utf8",
					timeout: 20000,
				});
			} catch {
				return; // 桥接不可用 → fail-open,与其它各家一致
			}
			if (!res || res.status !== 0 || !res.stdout || !res.stdout.trim()) return;

			let out;
			try {
				out = JSON.parse(res.stdout.trim());
			} catch {
				return;
			}

			if (out.level === "block" || out.level === "warn") {
				throw new Error(
					"[命令守卫] " + (out.reason || "危险命令") + " —— 别重试,换别的做法。",
				);
			}
		},
	};
};
