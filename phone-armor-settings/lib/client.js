/**
 * phone-armor-settings — 浏览器半边
 *
 * 在 DSH 设置面板里注册一个「手机强化」分节，三个模块开关：
 *   · 核心（破甲 + 预检 + 命令提示）—— 只读，必装
 *   · 外部生图通道 —— 开/关
 *   · 提示词强化包 —— 开/关（改动 prompt-inject.md，需重启生效）
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

		/** 模块级缓存：跨组件挂载保留已读到的状态，避免每次切进来都重新请求。 */
		let panelCache = null;

		const S = {
			wrap: { padding: "4px 2px 12px", maxWidth: "620px" },
			intro: { fontSize: "13px", color: "#8b9199", lineHeight: 1.6, marginBottom: "14px" },
			card: {
				background: "#161922", border: "1px solid #262b36", borderRadius: "12px",
				padding: "13px 14px", marginBottom: "11px"
			},
			row: { display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: "12px" },
			title: { fontSize: "14.5px", fontWeight: 600, color: "#e6e8ec", marginBottom: "4px" },
			desc: { fontSize: "12.5px", color: "#8b9199", lineHeight: 1.55 },
			badge: { fontSize: "11.5px", padding: "2px 8px", borderRadius: "6px", background: "#1e2430", color: "#8b9199", whiteSpace: "nowrap" },
			badgeOn: { background: "#14301c", color: "#7bd88f" },
			switchWrap: { flexShrink: 0, paddingTop: "2px" },
			switchBase: {
				width: "46px", height: "26px", borderRadius: "13px", border: "none",
				cursor: "pointer", position: "relative", transition: "background .15s"
			},
			knob: {
				position: "absolute", top: "3px", width: "20px", height: "20px", borderRadius: "50%",
				background: "#fff", transition: "left .15s"
			},
			btn: {
				padding: "10px 20px", fontSize: "14px", fontWeight: 600, color: "#fff",
				background: "#3d6ef5", border: "none", borderRadius: "9px", cursor: "pointer"
			},
			msg: { marginTop: "10px", fontSize: "13px", lineHeight: 1.55, wordBreak: "break-all" },
			ok: { color: "#7bd88f" },
			bad: { color: "#ff9d9d" },
			hint: { marginTop: "10px", fontSize: "12px", color: "#71787f", lineHeight: 1.55 }
		};

		function Switch({ on, onChange, disabled }) {
			return h("button", {
				style: {
					...S.switchBase,
					background: on ? "#2e7d32" : "#333a44",
					opacity: disabled ? 0.5 : 1,
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

		function PhoneArmorPanel() {
			// 模块级缓存：DSH 每次切进这个分节都会重新挂载组件，
			// 没有缓存就会每次都发一遍请求 —— 表现为「停留一会又变加载页」。
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
					// 失败也必须退出 loading，否则页面永远停在「读取中」
					setState(s => ({ ...s, loading: false }));
					setMsg({ ok: false, text: "读取失败：" + e.message });
				}
			}, []);

			react.useEffect(() => {
				if (panelCache) return;   // 已有缓存就不再请求
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

			const m = state.modules || {};
			const d = state.detect || {};

			if (state.loading) {
				return h("div", { style: S.wrap }, h("div", { style: S.intro }, "读取中…"));
			}

			return h("div", { style: S.wrap },
				h("div", { style: S.intro },
					"这些是可选功能。核心无需配置，装上就能用；下面两项按需开启，不开完全不影响正常使用。"
				),

				h(Card, {
					title: "核心",
					badge: d.purgeInstalled ? "已装" : "未装",
					badgeOn: d.purgeInstalled,
					desc: "破甲补丁 + 风险预检 + 命令提示 + 边界规则。必装项，不可关闭。",
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
					desc: "把额外的创作准则和描述模板合并进系统提示（" + (d.injectSize || 0) + " 字节）。开启后需重启引擎生效。",
					right: h(Switch, { on: !!m.boost, disabled: busy !== "", onChange: (v) => save({ boost: v }) })
				}),

				msg ? h("div", { style: { ...S.msg, ...(msg.ok ? S.ok : S.bad) } }, msg.text) : null,

				h("div", { style: S.hint },
					"状态存在 ~/.dsh/phone-armor/modules.json。命令行等价操作：sh armor.sh modules / ext on|off / boost on|off"
				)
			);
		}

		function apply(ctx) {
			ctx.slots.inject("settings.section", () =>
				ctx.slots.register(
					{
						name: "settings.section",
						id: "phone-armor",
						order: 60,
						label: () => "手机强化"
					},
					PhoneArmorPanel
				)
			);
		}

		exports.PhoneArmorPanel = PhoneArmorPanel;
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
