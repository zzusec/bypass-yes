/**
 * bypass-yes 命令守卫 · pi 扩展
 *
 * pi 没有 Claude 那种命令行 hook,拦截点是扩展的 tool_call 事件。本扩展在 bash 工具
 * 执行前调用 ~/.pi/agent/hooks/danger-guard-pi.py(判定引擎 core.py + 规则库 rules.py,
 * 和 Claude / Codex / CodeBuddy / zcode 同一份真源),拿回分级再决定:
 *
 *   block → 硬拦截({ block: true }),pi 不会执行该命令
 *   warn  → 弹真确认框(ctx.ui.confirm);无交互 UI(headless)时保守硬拦,绝不静默放行
 *   safe / allowlist → 放行(返回 undefined)
 *
 * pi 本身没有沙箱、默认不审批任何命令(等价于一直 yolo),这层守卫就是给它补上「别出事」。
 * 响铃由 python 桥接脚本负责(block/warn 都会响)。
 *
 * 安装:install-pi.sh 会把本文件复制到 ~/.pi/agent/extensions/(全局自动发现)。
 * 改完用 pi 内的 /reload 热加载,或重启 pi。
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import * as os from "node:os";
import * as path from "node:path";

export default function (pi: ExtensionAPI) {
	const HOOKS_DIR = path.join(os.homedir(), ".pi", "agent", "hooks");
	const GUARD = path.join(HOOKS_DIR, "danger-guard-pi.py");
	// 允许用 DANGER_GUARD_PY 指定解释器;默认 /usr/bin/python3(与本项目其它入口一致,macOS 自带)
	const PY = process.env.DANGER_GUARD_PY || "/usr/bin/python3";
	const TIMEOUT_MS = 20000;

	pi.on("tool_call", async (event, ctx) => {
		// 只管 bash 工具;read/write/edit 等不经过命令守卫
		if (!isToolCallEventType("bash", event)) return;

		const command = event.input.command;
		if (!command || !command.trim()) return;

		const cwd = ctx.cwd || process.cwd();
		const payload = JSON.stringify({ command, cwd });

		let res;
		try {
			res = await pi.exec(PY, [GUARD, payload], { cwd, timeout: TIMEOUT_MS });
		} catch {
			// 桥接不可用(python 缺失等)→ 放行,与其它入口的 fail-open 行为一致
			return;
		}
		if (!res || res.code !== 0 || !res.stdout || !res.stdout.trim()) return;

		let out: { level?: string; reason?: string };
		try {
			out = JSON.parse(res.stdout.trim());
		} catch {
			return;
		}

		const level = out.level;
		const reason = out.reason || "";

		if (level === "block") {
			if (ctx.hasUI) ctx.ui.notify("[命令守卫] 已拦截:" + reason, "warning");
			return { block: true, reason: "[命令守卫] " + reason };
		}

		if (level === "warn") {
			// 非交互模式(-p / --mode json / rpc 无对话框)弹不了确认 → 保守硬拦
			if (!ctx.hasUI) {
				return { block: true, reason: "[命令守卫] " + reason + "(非交互模式,保守拦截)" };
			}
			const shown = command.replace(/\s+/g, " ").slice(0, 400);
			const ok = await ctx.ui.confirm("[命令守卫] " + reason, shown + "\n\n仍要执行吗?");
			if (!ok) return { block: true, reason: "[命令守卫] 用户拒绝:" + reason };
			return; // 用户点了「是」→ 放行
		}

		// allowlist / safe → 放行
		return;
	});
}
