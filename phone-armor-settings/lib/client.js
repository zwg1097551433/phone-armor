/**
 * phone-armor-settings — 浏览器半边
 *
 * 两处注册，覆盖两种宿主：
 *   ① settings.section        网页版的设置面板（App 里会被降级成「在网页版打开」）
 *   ② conversation.input.dock App 里可用 —— 输入框上方一个齿轮，点开浮层就是开关
 *
 * 状态读写走 host 侧挂的 /phone-armor/modules。
 */
window.__ModuleLoader__.load({
	id: "phone-armor-settings",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		let react = require("react");
		const h = react.createElement;

		const inject = ["slots"];

		/** 模块级缓存：组件反复挂载时不再重复请求（DSH 每次切进分节都会重挂） */
		let panelCache = null;

		const S = {
			wrap: { padding: "4px 2px 12px", maxWidth: "620px" },
			intro: { fontSize: "13px", color: "#6b7280", lineHeight: 1.6, marginBottom: "14px" },
			card: {
				background: "#f7f8fa", border: "1px solid #e8ebf0", borderRadius: "12px",
				padding: "13px 14px", marginBottom: "11px"
			},
			row: { display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: "12px" },
			title: { fontSize: "14.5px", fontWeight: 600, color: "#1a1d23", marginBottom: "4px" },
			desc: { fontSize: "12.5px", color: "#6b7280", lineHeight: 1.55 },
			badge: { fontSize: "11.5px", padding: "2px 8px", borderRadius: "6px", background: "#eceff3", color: "#6b7280", whiteSpace: "nowrap" },
			badgeOn: { background: "#e6f6ea", color: "#1f7a33" },
			switchWrap: { flexShrink: 0, paddingTop: "2px" },
			switchBase: {
				width: "46px", height: "26px", borderRadius: "13px", border: "none",
				cursor: "pointer", position: "relative", transition: "background .15s"
			},
			knob: {
				position: "absolute", top: "3px", width: "20px", height: "20px", borderRadius: "50%",
				background: "#fff", boxShadow: "0 1px 3px rgba(0,0,0,.22)", transition: "left .15s"
			},
			msg: { marginTop: "10px", fontSize: "13px", lineHeight: 1.55, wordBreak: "break-all" },
			ok: { color: "#1f7a33" },
			bad: { color: "#c62828" },
			hint: { marginTop: "10px", fontSize: "12px", color: "#9aa1ab", lineHeight: 1.55 },

			// —— dock 入口 ——
			gear: {
				display: "inline-flex", alignItems: "center", gap: "5px",
				padding: "4px 9px", marginRight: "6px",
				fontSize: "12.5px", color: "#6b7280",
				background: "#fff", border: "1px solid #e2e6ec",
				borderRadius: "8px", cursor: "pointer", lineHeight: 1.3
			},
			gearDot: { width: "6px", height: "6px", borderRadius: "50%", background: "#c9cfd8" },
			gearDotOn: { background: "#34a853" },

			overlay: {
				position: "fixed", top: 0, left: 0, right: 0, bottom: 0,
				zIndex: 2147482000, background: "rgba(20, 24, 30, 0.34)",
				display: "flex", alignItems: "center", justifyContent: "center", padding: "14px",
				boxSizing: "border-box"
			},
			sheet: {
				width: "100%", maxWidth: "560px", maxHeight: "86vh",
				display: "flex", flexDirection: "column",
				background: "#ffffff", border: "1px solid #e8ebf0", borderRadius: "16px",
				boxShadow: "0 18px 50px rgba(17,24,39,.22)", overflow: "hidden"
			},
			sheetHead: {
				padding: "14px 16px 12px", display: "flex", alignItems: "center",
				justifyContent: "space-between", borderBottom: "1px solid #eef1f5"
			},
			sheetTitle: { fontSize: "15.5px", fontWeight: 700, color: "#111418" },
			close: {
				fontSize: "13px", color: "#4b5563", background: "#fff",
				border: "1px solid #dfe3e9", borderRadius: "8px", padding: "6px 14px", cursor: "pointer"
			},
			sheetBody: { padding: "14px 16px 16px", overflowY: "auto", WebkitOverflowScrolling: "touch" }
		};

		function Switch({ on, onChange, disabled }) {
			return h("button", {
				style: {
					...S.switchBase,
					background: on ? "#34a853" : "#d5d9e0",
					opacity: disabled ? 0.45 : 1,
					cursor: disabled ? "not-allowed" : "pointer"
				},
				onClick: () => { if (!disabled) onChange(!on); },
				"aria-pressed": on ? "true" : "false"
			}, h("span", { style: { ...S.knob, left: on ? "23px" : "3px" } }));
		}

		function Card({ title, desc, badge, badgeOn, right }) {
			return h("div", { style: S.card },
				h("div", { style: S.row },
					h("div", { style: { flex: 1, minWidth: 0 } },
						h("div", { style: S.title }, title,
							badge ? h("span", { style: { ...S.badge, ...(badgeOn ? S.badgeOn : {}), marginLeft: "8px" } }, badge) : null
						),
						desc ? h("div", { style: S.desc }, desc) : null
					),
					right ? h("div", { style: S.switchWrap }, right) : null
				)
			);
		}

		/** 状态与读写：设置页和浮层共用。 */
		function useModules() {
			const [state, setState] = react.useState(() =>
				panelCache
					? { loading: false, modules: panelCache.modules, detect: panelCache.detect }
					: { loading: true, modules: { core: true, ext: false, boost: false }, detect: {} }
			);
			const [busy, setBusy] = react.useState("");
			const [msg, setMsg] = react.useState(null);

			const load = react.useCallback(async () => {
				try {
					const r = await fetch("/phone-armor/modules", { headers: { Accept: "application/json" } });
					const j = await r.json();
					if (j.ok) {
						panelCache = { modules: j.modules, detect: j.detect || {} };
						setState({ loading: false, modules: j.modules, detect: j.detect || {} });
					} else {
						setState(s => ({ ...s, loading: false }));
						setMsg({ ok: false, text: j.msg || "读取失败" });
					}
				} catch (e) {
					setState(s => ({ ...s, loading: false }));
					setMsg({ ok: false, text: "读取失败：" + e.message });
				}
			}, []);

			react.useEffect(() => {
				if (panelCache && panelCache.modules) {
					// 有缓存也要在后台刷一次，但不清空界面
					load();
					return;
				}
				load();
			}, [load]);

			async function save(patch) {
				setBusy(JSON.stringify(patch));
				setMsg(null);
				try {
					const r = await fetch("/phone-armor/modules", {
						method: "POST",
						headers: { "Content-Type": "application/json" },
						body: JSON.stringify(patch)
					});
					const j = await r.json();
					if (j.ok) {
						panelCache = { modules: j.modules, detect: j.detect || {} };
						setState({ loading: false, modules: j.modules, detect: j.detect || {} });
						const extra = j.note ? "（" + j.note + "）" : "";
						setMsg({ ok: true, text: "已保存" + extra });
					} else {
						setMsg({ ok: false, text: j.msg || "保存失败" });
					}
				} catch (e) {
					setMsg({ ok: false, text: "保存失败：" + e.message });
				} finally {
					setBusy("");
				}
			}

			return { state, busy, msg, save };
		}

		/** 三张卡片 + 保存反馈，设置页和浮层共用同一份。 */
		function SettingsBody({ compact }) {
			const { state, busy, msg, save } = useModules();
			const m = state.modules || {};
			const d = state.detect || {};

			if (state.loading) {
				return h("div", { style: S.intro }, "读取中…");
			}

			return h("div", null,
				h("div", { style: S.intro },
					"可选功能。核心装上就能用；下面两项按需开启，不开完全不影响正常使用。"
				),

				h(Card, {
					title: "核心",
					badge: d.purgeInstalled ? "已装" : "未装",
					badgeOn: d.purgeInstalled,
					desc: "破甲补丁 + 风险预检 + 命令提示 + 边界规则。必装，不可关闭。",
					right: h(Switch, { on: true, disabled: true, onChange: () => {} })
				}),

				h(Card, {
					title: "外部生图通道",
					badge: m.ext ? "已开启" : "未开启",
					badgeOn: m.ext,
					desc: "开启后可以用自己买的云端生图 API 直接出图，不经过模型判断。配置页：node tools/gen-config.mjs",
					right: h(Switch, { on: !!m.ext, disabled: busy !== "", onChange: (v) => save({ ext: v }) })
				}),

				h(Card, {
					title: "提示词强化包",
					badge: m.boost ? "已开启" : "未开启",
					badgeOn: m.boost,
					desc: "把额外的创作准则和描述模板合并进系统提示（当前 " + (d.injectSize || 0) + " 字节）。开启后需重启引擎生效。",
					right: h(Switch, { on: !!m.boost, disabled: busy !== "", onChange: (v) => save({ boost: v }) })
				}),

				msg ? h("div", { style: { ...S.msg, ...(msg.ok ? S.ok : S.bad) } }, msg.text) : null,

				compact ? null : h("div", { style: S.hint },
					"状态存在 ~/.dsh/phone-armor/modules.json。命令行等价：sh armor.sh modules"
				)
			);
		}

		/** ① 设置面板里的分节（网页版用） */
		function PhoneArmorPanel() {
			return h("div", { style: S.wrap }, h(SettingsBody, {}));
		}

		/** ② 输入框上方的齿轮入口 + 浮层（App 里用） */
		function GearEntry() {
			const [open, setOpen] = react.useState(false);
			const { state } = useModules();
			const m = state.modules || {};
			const anyOn = !!m.ext || !!m.boost;

			return h(react.Fragment, null,
				h("button", {
					style: S.gear,
					onClick: () => setOpen(true),
					title: "手机强化设置"
				},
					h("span", { style: { ...S.gearDot, ...(anyOn ? S.gearDotOn : {}) } }),
					"手机强化"
				),

				open ? h("div", { style: S.overlay, role: "dialog", "aria-modal": "true" },
					h("div", { style: S.sheet },
						h("div", { style: S.sheetHead },
							h("span", { style: S.sheetTitle }, "手机强化"),
							h("button", { style: S.close, onClick: () => setOpen(false) }, "关闭")
						),
						h("div", { style: S.sheetBody }, h(SettingsBody, { compact: true }))
					)
				) : null
			);
		}

		function apply(ctx) {
			// 设置面板分节：网页版可见；App 里会被降级成「在网页版打开」，无副作用
			ctx.slots.inject("settings.section", () =>
				ctx.slots.register(
					{ name: "settings.section", id: "phone-armor", order: 60, label: () => "手机强化" },
					PhoneArmorPanel
				)
			);

			// 输入框上方的齿轮：App 里也能用
			ctx.slots.inject("conversation.input.dock", () =>
				ctx.slots.register(
					{ name: "conversation.input.dock", id: "phone-armor-gear", order: 5 },
					GearEntry
				)
			);
		}

		exports.PhoneArmorPanel = PhoneArmorPanel;
		exports.GearEntry = GearEntry;
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
