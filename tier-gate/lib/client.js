window.__ModuleLoader__.load({
	id: "phone-armor-tier-gate",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		let react = require("react");

		/** 本插件占用的服务：只要插槽系统。 */
		const inject = ["slots"];

		/** localStorage 键：'1' = 不再弹；'0' 或空 = 下次启动还弹。 */
		const KEY = "phone-armor.tier-gate.ack";

		const BODY = `
<style>
  .pa-t { margin: 0 0 12px; padding: 11px 13px; border-radius: 10px; background: #1b1e24; border-left: 4px solid #3d4450; }
  .pa-t:last-child { margin-bottom: 0; }
  .pa-h { font-size: 14px; font-weight: 700; margin-bottom: 6px; color: #e8eaed; }
  .pa-b { font-size: 13px; line-height: 1.6; color: #b9bec7; }
  .pa-n { font-size: 12px; line-height: 1.55; margin-top: 7px; color: #8b9199; }
  .pa-1 { border-left-color: #2e7d32; }
  .pa-1 .pa-h { color: #7bd88f; }
  .pa-2 { border-left-color: #ed6c02; }
  .pa-2 .pa-h { color: #ffb74d; }
  .pa-3 { border-left-color: #d32f2f; background: #2a1214; }
  .pa-3 .pa-h { color: #ff5252; }
  .pa-3 .pa-b { color: #ffb3b3; }
  .pa-3 .pa-n { color: #ff8a8a; }
  .pa-3 b { color: #ff5252; }
</style>
<div class="pa-t pa-1">
  <div class="pa-h">① 随时可用</div>
  <div class="pa-b">对话 / 写作 / 翻译 / 总结、读文件与搜索、写代码改脚本、轻量 shell、生成 docx·xlsx·pptx、几 MB 文本处理、会话与任务管理、调用云端生图</div>
</div>
<div class="pa-t pa-2">
  <div class="pa-h">② 能跑，但手机会烫 / 卡</div>
  <div class="pa-b">50–500 MB 大文本、批量文件、npm install 与小项目编译、LibreOffice 转 PDF、子代理 ≤3、nmap -sT 单目标、小字典爆破、短片转码、单条隧道、超长对话</div>
  <div class="pa-n">动手前我会先说清「预计多久、多烫、多少电和流量」，并给出转电脑的选项。</div>
</div>
<div class="pa-t pa-3">
  <div class="pa-h">⛔ ③ 手机上跑不了（会卡死 / 被杀）</div>
  <div class="pa-b">本地生图 · 本地大模型推理 · 大容量视频生成与 4K 渲染 · masscan 与大网段 SYN 扫描 · hashcat GPU 破解 · 内网渗透全套 · 编译大项目 · 几十个 agent 并发 · GB 级数据集 · Docker · 需要 root 的操作 · GUI 程序</div>
  <div class="pa-n"><b>这些不是配置问题，是硬件与系统限制</b>：没有 GPU、没有 root、被动散热、单进程内存 2–4 GB、切后台会被回收。<br>能云端做的我会直接改走云端；只能本地跑的，我会告诉你在电脑上怎么做。</div>
</div>
`;

		const S = {
			overlay: {
				position: "fixed",
				top: 0,
				left: 0,
				right: 0,
				bottom: 0,
				zIndex: 2147483000,
				background: "rgba(6, 8, 12, 0.86)",
				display: "flex",
				alignItems: "center",
				justifyContent: "center",
				padding: "14px",
				boxSizing: "border-box"
			},
			card: {
				width: "100%",
				maxWidth: "560px",
				maxHeight: "86vh",
				display: "flex",
				flexDirection: "column",
				background: "#12141a",
				border: "1px solid #2c313a",
				borderRadius: "14px",
				boxShadow: "0 18px 60px rgba(0,0,0,.6)",
				overflow: "hidden"
			},
			head: {
				padding: "14px 16px 10px",
				display: "flex",
				alignItems: "baseline",
				gap: "8px",
				borderBottom: "1px solid #23272f"
			},
			badge: { fontSize: "16px", fontWeight: 700, color: "#e8eaed" },
			sub: { fontSize: "11px", color: "#7b828c" },
			scroll: {
				padding: "14px 16px",
				overflowY: "auto",
				WebkitOverflowScrolling: "touch"
			},
			footer: {
				padding: "11px 16px",
				display: "flex",
				gap: "9px",
				justifyContent: "flex-end",
				borderTop: "1px solid #23272f",
				background: "#0e1015"
			},
			btn: {
				padding: "9px 18px",
				fontSize: "13px",
				fontWeight: 600,
				color: "#fff",
				background: "#d32f2f",
				border: "none",
				borderRadius: "8px",
				cursor: "pointer"
			},
			btnGhost: {
				padding: "9px 14px",
				fontSize: "13px",
				color: "#b9bec7",
				background: "transparent",
				border: "1px solid #333a44",
				borderRadius: "8px",
				cursor: "pointer"
			}
		};

		function readAck() {
			try {
				return window.localStorage.getItem(KEY);
			} catch (e) {
				return null;
			}
		}

		function writeAck(value) {
			try {
				window.localStorage.setItem(KEY, value);
			} catch (e) {
				/* 隐私模式下写不进去就算了，下次还弹 */
			}
		}

		/**
		 * 三档能力闸门。
		 *
		 * 刻意用同步读 localStorage：不复制 EnvAdaptSendGate 那个
		 * 「异步刷新但不等结果」的时序 bug。读不到就当作没确认过，宁可多弹一次。
		 */
		function TierGate() {
			const [open, setOpen] = react.useState(() => readAck() !== "1");
			if (!open) return null;
			const close = (value) => {
				writeAck(value);
				setOpen(false);
			};
			return react.createElement(
				"div",
				{ style: S.overlay, role: "dialog", "aria-modal": "true" },
				react.createElement(
					"div",
					{ style: S.card },
					react.createElement(
						"div",
						{ style: S.head },
						react.createElement("span", { style: S.badge }, "这台手机能做什么"),
						react.createElement("span", { style: S.sub }, "DSH Go · 本机引擎")
					),
					react.createElement("div", {
						style: S.scroll,
						dangerouslySetInnerHTML: { __html: BODY }
					}),
					react.createElement(
						"div",
						{ style: S.footer },
						react.createElement(
							"button",
							{ style: S.btnGhost, onClick: () => close("0") },
							"每次启动都提醒"
						),
						react.createElement(
							"button",
							{ style: S.btn, onClick: () => close("1") },
							"我知道了"
						)
					)
				)
			);
		}

		/**
		 * 插件主体：把闸门挂到输入框上方的 dock 插槽。
		 * 因为组件自身用 position:fixed 覆盖全屏，挂在哪个插槽不影响展示位置。
		 */
		function apply(ctx) {
			ctx.slots.inject("conversation.input.dock", () =>
				ctx.slots.register(
					{
						name: "conversation.input.dock",
						id: "phone-armor-tier-gate",
						order: 1
					},
					TierGate
				)
			);
		}

		exports.TierGate = TierGate;
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
