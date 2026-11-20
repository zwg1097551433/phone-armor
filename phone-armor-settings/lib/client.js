/**
 * phone-armor-settings — 浏览器半边
 *
 * 两处注册：
 *   ① settings.section        网页版设置面板
 *   ② conversation.input.dock App 里输入框上方「手机强化」，点开全屏设置页（Portal 到 body）
 *
 * 页面内容：
 *   · 核心（只读）
 *   · 外部生图通道开关 + API 配置表单（填完即可用，不用跑命令行）
 *   · 提示词强化包开关
 */
window.__ModuleLoader__.load({
	id: "phone-armor-settings",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		let react = require("react");
		const h = react.createElement;

		// dock 容器带 transform，position:fixed 会失效 —— 浮层必须 Portal 到 body
		let createPortal = null;
		try {
			const rd = require("react-dom");
			createPortal = rd.createPortal || (rd.default && rd.default.createPortal) || null;
		} catch {
			createPortal = null;
		}

		const inject = ["slots"];

		const LS_MODULES = "phone-armor.modules.v1";
		const LS_GEN = "phone-armor.genconf.v1";

		function lsRead(key) {
			try {
				const raw = window.localStorage.getItem(key);
				return raw ? JSON.parse(raw) : null;
			} catch {
				return null;
			}
		}
		function lsWrite(key, value) {
			try {
				window.localStorage.setItem(key, JSON.stringify(value));
			} catch {
				/* 隐私模式忽略 */
			}
		}

		const S = {
			wrap: { padding: "4px 2px 12px", maxWidth: "620px" },
			intro: { fontSize: "13px", color: "#6b7280", lineHeight: 1.6, marginBottom: "14px" },
			card: { background: "#f7f8fa", border: "1px solid #e8ebf0", borderRadius: "12px", padding: "13px 14px", marginBottom: "11px" },
			row: { display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: "12px" },
			title: { fontSize: "14.5px", fontWeight: 600, color: "#1a1d23", marginBottom: "4px" },
			desc: { fontSize: "12.5px", color: "#6b7280", lineHeight: 1.55 },
			badge: { fontSize: "11.5px", padding: "2px 8px", borderRadius: "6px", background: "#eceff3", color: "#6b7280", whiteSpace: "nowrap" },
			badgeOn: { background: "#e6f6ea", color: "#1f7a33" },
			switchWrap: { flexShrink: 0, paddingTop: "2px" },
			switchBase: { width: "46px", height: "26px", borderRadius: "13px", border: "none", cursor: "pointer", position: "relative", transition: "background .15s" },
			knob: { position: "absolute", top: "3px", width: "20px", height: "20px", borderRadius: "50%", background: "#fff", boxShadow: "0 1px 3px rgba(0,0,0,.22)", transition: "left .15s" },

			form: { marginTop: "12px", paddingTop: "12px", borderTop: "1px dashed #dfe3e9" },
			label: { display: "block", fontSize: "12.5px", color: "#4b5563", margin: "10px 0 5px" },
			firstLabel: { marginTop: "0" },
			input: { width: "100%", padding: "10px 11px", fontSize: "14px", color: "#111418", background: "#fff", border: "1px solid #dfe3e9", borderRadius: "9px", boxSizing: "border-box", fontFamily: "inherit", outline: "none" },
			select: { width: "100%", padding: "10px 11px", fontSize: "14px", color: "#111418", background: "#fff", border: "1px solid #dfe3e9", borderRadius: "9px", boxSizing: "border-box", fontFamily: "inherit" },
			tip: { fontSize: "11.5px", color: "#9aa1ab", marginTop: "5px", lineHeight: 1.5 },
			actions: { display: "flex", gap: "9px", marginTop: "13px" },
			btn: { flex: 1, padding: "11px", fontSize: "14px", fontWeight: 600, color: "#fff", background: "#3d6ef5", border: "none", borderRadius: "9px", cursor: "pointer" },
			btnGhost: { flex: 1, padding: "11px", fontSize: "14px", fontWeight: 600, color: "#4b5563", background: "#fff", border: "1px solid #dfe3e9", borderRadius: "9px", cursor: "pointer" },

			msg: { marginTop: "10px", fontSize: "13px", lineHeight: 1.55, wordBreak: "break-all" },
			ok: { color: "#1f7a33" },
			bad: { color: "#c62828" },
			hint: { marginTop: "10px", fontSize: "12px", color: "#9aa1ab", lineHeight: 1.55 },

			gear: { display: "inline-flex", alignItems: "center", gap: "5px", padding: "4px 9px", marginRight: "6px", fontSize: "12.5px", color: "#6b7280", background: "#fff", border: "1px solid #e2e6ec", borderRadius: "8px", cursor: "pointer", lineHeight: 1.3 },
			gearDot: { width: "6px", height: "6px", borderRadius: "50%", background: "#c9cfd8" },
			gearDotOn: { background: "#34a853" },

			overlay: {
				position: "fixed", top: 0, left: 0, right: 0, bottom: 0,
				zIndex: 2147482000, background: "#ffffff",
				display: "flex", flexDirection: "column", boxSizing: "border-box",
				// 移动端渲染优化：提升为独立合成层，避免全屏重排拖慢打开速度
				contain: "layout paint",
				willChange: "transform",
				transform: "translateZ(0)"
			},
			sheet: { width: "100%", height: "100%", display: "flex", flexDirection: "column", background: "#ffffff" },
			sheetHead: { flexShrink: 0, padding: "14px 16px 12px", paddingTop: "max(14px, env(safe-area-inset-top))", display: "flex", alignItems: "center", justifyContent: "space-between", borderBottom: "1px solid #eef1f5" },
			sheetTitle: { fontSize: "16px", fontWeight: 700, color: "#111418" },
			close: { fontSize: "13px", color: "#4b5563", background: "#fff", border: "1px solid #dfe3e9", borderRadius: "8px", padding: "6px 14px", cursor: "pointer" },
			sheetBody: { flex: 1, minHeight: 0, padding: "14px 16px 24px", paddingBottom: "calc(24px + env(safe-area-inset-bottom))", overflowY: "auto", WebkitOverflowScrolling: "touch" }
		};

		function Switch({ on, onChange, disabled }) {
			return h("button", {
				style: { ...S.switchBase, background: on ? "#34a853" : "#d5d9e0", opacity: disabled ? 0.45 : 1, cursor: disabled ? "not-allowed" : "pointer" },
				onClick: () => { if (!disabled) onChange(!on); },
				"aria-pressed": on ? "true" : "false"
			}, h("span", { style: { ...S.knob, left: on ? "23px" : "3px" } }));
		}

		function Card({ title, desc, badge, badgeOn, right, children }) {
			return h("div", { style: S.card },
				h("div", { style: S.row },
					h("div", { style: { flex: 1, minWidth: 0 } },
						h("div", { style: S.title }, title,
							badge ? h("span", { style: { ...S.badge, ...(badgeOn ? S.badgeOn : {}), marginLeft: "8px" } }, badge) : null
						),
						desc ? h("div", { style: S.desc }, desc) : null
					),
					right ? h("div", { style: S.switchWrap }, right) : null
				),
				children || null
			);
		}

		// ---------------------------------------------------------------- 数据源
		function useModules() {
			const [state, setState] = react.useState(() => {
				const cached = lsRead(LS_MODULES);
				if (cached && cached.modules) return { modules: cached.modules, detect: cached.detect || {}, conf: cached.conf || null };
				return { modules: { core: true, ext: false, boost: false }, detect: {}, conf: null };
			});
			const [busy, setBusy] = react.useState("");
			const [msg, setMsg] = react.useState(null);

			const load = react.useCallback(async () => {
				try {
					const r = await fetch("/phone-armor/modules", { headers: { Accept: "application/json" } });
					const j = await r.json();
					if (j.ok) {
						const next = { modules: j.modules, detect: j.detect || {}, conf: j.conf || null };
						lsWrite(LS_MODULES, next);
						setState(next);
					}
				} catch (e) {
					setMsg({ ok: false, text: "同步失败，显示的是上次状态" });
				}
			}, []);

			react.useEffect(() => { load(); }, [load]);

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
						const next = { modules: j.modules, detect: j.detect || {}, conf: j.conf || state.conf };
						lsWrite(LS_MODULES, next);
						setState(next);
						setMsg({ ok: true, text: "已保存" + (j.note ? "（" + j.note + "）" : "") });
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

		function useGenConf(seed) {
			// 初始值来自 localStorage；服务端数据由 useModules 一起带回来，不再单独请求
			const [conf, setConf] = react.useState(() => lsRead(LS_GEN) || { endpoint: "", model: "", format: "openai", hasKey: false, keyHint: "" });
			const [busy, setBusy] = react.useState(false);
			const [msg, setMsg] = react.useState(null);

			react.useEffect(() => {
				if (seed && seed.endpoint !== undefined) {
					lsWrite(LS_GEN, seed);
					setConf(seed);
				}
			}, [seed]);

			async function save(body) {
				setBusy(true);
				setMsg(null);
				try {
					const r = await fetch("/phone-armor/genconf", {
						method: "POST",
						headers: { "Content-Type": "application/json" },
						body: JSON.stringify(body)
					});
					const j = await r.json();
					if (j.ok) {
						lsWrite(LS_GEN, j.conf);
						setConf(j.conf);
						setMsg({ ok: true, text: "已保存。出图命令：sh tools/gen-image.sh \"描述\"" });
					} else {
						setMsg({ ok: false, text: j.msg || "保存失败" });
					}
				} catch (e) {
					setMsg({ ok: false, text: "保存失败：" + e.message });
				} finally {
					setBusy(false);
				}
			}

			return { conf, busy, msg, save };
		}

		// ---------------------------------------------------------------- 内容
		function GenConfForm({ gen }) {
			const { conf, busy, msg, save } = gen;
			const [endpoint, setEndpoint] = react.useState(conf.endpoint || "");
			const [model, setModel] = react.useState(conf.model || "");
			const [format, setFormat] = react.useState(conf.format || "openai");
			const [key, setKey] = react.useState("");

			react.useEffect(() => {
				setEndpoint(conf.endpoint || "");
				setModel(conf.model || "");
				setFormat(conf.format || "openai");
			}, [conf.endpoint, conf.model, conf.format]);

			return h("div", { style: S.form },
				h("label", { style: { ...S.label, ...S.firstLabel } }, "接口格式"),
				h("select", { style: S.select, value: format, onChange: (e) => setFormat(e.target.value) },
					h("option", { value: "openai" }, "OpenAI 兼容（/v1/images/generations）"),
					h("option", { value: "novelai" }, "NovelAI（/ai/generate-image）")
				),

				h("label", { style: S.label }, "API 地址" + (format === "novelai" ? "（可留空）" : "")),
				h("input", {
					style: S.input, value: endpoint, placeholder: "https://api.example.com/v1",
					onChange: (e) => setEndpoint(e.target.value), spellCheck: false, autoComplete: "off"
				}),

				h("label", { style: S.label }, "API Key"),
				h("input", {
					style: S.input, value: key, type: "password",
					placeholder: conf.hasKey ? "已保存 " + (conf.keyHint || "") + "（留空则不修改）" : "粘贴你的 key",
					onChange: (e) => setKey(e.target.value), spellCheck: false, autoComplete: "off"
				}),
				h("div", { style: S.tip }, "只存在手机本地 ~/.phone-armor/gen.conf（权限 600），不会上传。"),

				h("label", { style: S.label }, "模型名（可留空）"),
				h("input", {
					style: S.input, value: model, placeholder: "例如 flux / nai-diffusion-3",
					onChange: (e) => setModel(e.target.value), spellCheck: false, autoComplete: "off"
				}),

				h("div", { style: S.actions },
					h("button", {
						style: S.btn, disabled: busy,
						onClick: () => save({ endpoint, model, format, key })
					}, busy ? "保存中…" : "保存配置")
				),

				msg ? h("div", { style: { ...S.msg, ...(msg.ok ? S.ok : S.bad) } }, msg.text) : null
			);
		}

		function SettingsBody({ mod, gen }) {
			const m = mod.state.modules || {};
			const d = mod.state.detect || {};

			return h("div", null,
				h("div", { style: S.intro }, "可选功能。核心装上就能用；下面两项按需开启，不开完全不影响正常使用。"),

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
					desc: "用自己的云端生图 API 出图，不经过模型判断。开启后填下面的配置即可用。",
					right: h(Switch, { on: !!m.ext, disabled: mod.busy !== "", onChange: (v) => { mod.save({ ext: v }); } })
				}, m.ext ? h(GenConfForm, { gen }) : null),

				h(Card, {
					title: "注入模式",
					badge: d.injectMode === "core" ? "精简（仅 L1）" : "完整（L1+L2）",
					badgeOn: d.injectMode === "core",
					desc: d.injectMode === "core"
						? "当前只有执行纪律（身份/多轮/输出/意图/边界词），不含手机能力边界。最接近原版行为。"
						: "执行纪律 + 手机能力边界（三档评级、转场阈值、水印处理）。切换需在终端执行命令。",
					right: null
				}),

				h(Card, {
					title: "提示词强化包",
					badge: m.boost ? "已开启" : "未开启",
					badgeOn: m.boost,
					desc: "把额外的创作准则和描述模板合并进系统提示（当前 " + (d.injectSize || 0) + " 字节）。开启后需重启引擎生效。",
					right: h(Switch, { on: !!m.boost, disabled: mod.busy !== "", onChange: (v) => mod.save({ boost: v }) })
				}),

				mod.msg ? h("div", { style: { ...S.msg, ...(mod.msg.ok ? S.ok : S.bad) } }, mod.msg.text) : null,

				h("div", { style: S.hint }, "状态存在 ~/.dsh/phone-armor/modules.json；API 凭据在 ~/.phone-armor/gen.conf。")
			);
		}

		/** ① 网页版设置面板 */
		function PhoneArmorPanel() {
			const mod = useModules();
			const gen = useGenConf(mod.state.conf);
			return h("div", { style: S.wrap }, h(SettingsBody, { mod, gen }));
		}

		/** ② App 里的齿轮 + 全屏设置页 */
		function GearEntry() {
			const [open, setOpen] = react.useState(false);
			const mod = useModules();
			const gen = useGenConf(mod.state.conf);
			const m = mod.state.modules || {};
			const anyOn = !!m.ext || !!m.boost;

			const panel = h("div", { style: S.overlay, role: "dialog", "aria-modal": "true" },
				h("div", { style: S.sheet },
					h("div", { style: S.sheetHead },
						h("span", { style: S.sheetTitle }, "手机强化"),
						h("button", { style: S.close, onClick: () => setOpen(false) }, "关闭")
					),
					h("div", { style: S.sheetBody }, h(SettingsBody, { mod, gen }))
				)
			);

			return h(react.Fragment, null,
				h("button", { style: S.gear, onClick: () => setOpen(true), title: "手机强化设置" },
					h("span", { style: { ...S.gearDot, ...(anyOn ? S.gearDotOn : {}) } }),
					"手机强化"
				),
				open ? (createPortal && document && document.body ? createPortal(panel, document.body) : panel) : null
			);
		}

		function apply(ctx) {
			ctx.slots.inject("settings.section", () =>
				ctx.slots.register({ name: "settings.section", id: "phone-armor", order: 60, label: () => "手机强化" }, PhoneArmorPanel)
			);
			ctx.slots.inject("conversation.input.dock", () =>
				ctx.slots.register({ name: "conversation.input.dock", id: "phone-armor-gear", order: 5 }, GearEntry)
			);
		}

		exports.PhoneArmorPanel = PhoneArmorPanel;
		exports.GearEntry = GearEntry;
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
